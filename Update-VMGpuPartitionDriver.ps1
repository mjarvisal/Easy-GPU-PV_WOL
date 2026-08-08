<# 
If you are opening this file in Powershell ISE you should modify the params section like so...
Remember: GPU Name must match the name of the GPU you assigned when creating the VM...

Param (
[string]$VMName = "NameofyourVM",
[string]$GPUName = "NameofyourGPU",
[string]$Hostname = $ENV:Computername
)

#>

Param (
[string]$VMName,
[string]$GPUName,
[string]$Hostname = $ENV:Computername
)

$PSScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition

Write-Host "INFO   : Importing module..."
Write-Host "INFO   : GPU Name: $GPUName"

Remove-Module $PSSCriptRoot\Add-VMGpuPartitionAdapterFiles.psm1
Import-Module $PSSCriptRoot\Add-VMGpuPartitionAdapterFiles.psm1

$VM = Get-VM -VMName $VMName
$VHD = Get-VHD -VMId $VM.VMId

If ($VM.state -eq "Running") {
    [bool]$state_was_running = $true
    }

if ($VM.state -ne "Off"){
    "Attemping to shutdown VM..."
    Stop-VM -Name $VMName -Force
    } 

While ($VM.State -ne "Off") {
    Start-Sleep -s 3
    "Waiting for VM to shutdown - make sure there are no unsaved documents..."
    }

"Mounting Drive..."
$MountedDisk = Mount-VHD -Path $VHD.Path -PassThru | Get-Disk
$Volume = $MountedDisk | Get-Partition | Get-Volume | Where-Object {$_.DriveLetter}

if (-not $Volume) {
    # Known issue on Windows 11 24H2 hosts: Mount-VHD sometimes doesn't auto-assign a
    # drive letter to the mounted partition. If we don't catch this, DriveLetter ends up
    # empty and every downstream Copy-Item silently fails or writes to the wrong place
    # while the script still reports success. See: https://github.com/jamesstringer90/Easy-GPU-PV/issues/404
    "WARN   : No drive letter was auto-assigned to the mounted VHD. Assigning one manually..."
    $WindowsPartition = $MountedDisk | Get-Partition | Where-Object {$_.Type -eq 'Basic'} | Sort-Object Size -Descending | Select-Object -First 1
    $WindowsPartition | Add-PartitionAccessPath -AssignDriveLetter -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    $Volume = $MountedDisk | Get-Partition | Get-Volume | Where-Object {$_.DriveLetter}
}

if (-not $Volume) {
    Write-Error "ERROR  : Still could not obtain a drive letter for the mounted VHD after manual assignment. Dismounting and aborting - no files were copied. Try mounting the VHD manually and assigning a drive letter via Disk Management once, then re-run this script."
    Dismount-VHD -Path $VHD.Path
    exit 1
}

$DriveLetter = ($Volume | Select-Object -First 1).DriveLetter
"Drive Letter: $DriveLetter"

"Copying GPU Files - this could take a while..."
Add-VMGPUPartitionAdapterFiles -hostname $Hostname -DriveLetter $DriveLetter -GPUName $GPUName

# Verify something actually landed on the VM disk before declaring success - the original
# script would print "Done..." even when every copy operation had failed.
$CopiedFileCount = (Get-ChildItem -Path "${DriveLetter}:\Windows\System32\HostDriverStore" -Recurse -File -ErrorAction SilentlyContinue | Measure-Object).Count
if ($CopiedFileCount -eq 0) {
    Write-Warning "WARN   : HostDriverStore on the VM disk is empty after the copy step - the driver copy likely failed. Double-check that -GPUName matches Device Manager's name on the host exactly (or use AUTO), and review the output above for errors."
} else {
    "INFO   : Verified $CopiedFileCount driver files copied to HostDriverStore."
}

"Dismounting Drive..."
Dismount-VHD -Path $VHD.Path

If ($state_was_running){
    "Previous State was running so starting VM..."
    Start-VM $VMName
    }

"Done..."