#Requires -RunAsAdministrator
<#
.SYNOPSIS
Re-syncs the GPU-PV guest with the host: driver files (via Add-VMGpuPartitionAdapterFiles.psm1)
and, optionally, the host's dxgkrnl-family kernel files.

.EXAMPLE
powershell.exe -ExecutionPolicy Bypass -File .\Update-VMGpuPartitionDriver.ps1 -VMName GamingPC -GPUName "AUTO" -CleanStaleDriverStore

.NOTES
-CleanStaleDriverStore removes the guest's old NVIDIA files before copying: the nv_dispi* folders in
HostDriverStore, plus nv* files in System32/SysWOW64 and mcu.exe. The module prints "driver files already
exist in VM, skipping copy" for files that are already there, so without this step old-version user-mode
files can survive a host driver update.

System files (dxgkrnl.sys, dxgmms1.sys, dxgmms2.sys) are only copied when the host and guest Windows build
numbers match (as reported by ntoskrnl.exe). Use -IgnoreBuildMismatch to override, but mixing kernel files
across Windows builds can leave the guest unbootable. Originals are backed up to
.\SystemFileBackup\<VMName>\<timestamp>\ before being replaced.

If the module's Copy-Item hits "access denied" on an offline guest file, the script takes ownership of that
file and runs the copy again (up to 40 times).
#>

Param (
    [Parameter(Mandatory)][string]$VMName,
    [Parameter(Mandatory)][string]$GPUName,
    [string]$Hostname = $ENV:Computername,
    [switch]$SkipSystemFiles,          # don't copy dxgkrnl and friends
    [switch]$CleanStaleDriverStore,    # remove old NVIDIA files from the guest before copying (see NOTES)
    [switch]$IgnoreBuildMismatch,      # copy system files even if host/guest build numbers differ
    [string[]]$ExtraSystemFiles = @()  # extra files relative to C:\Windows, e.g. 'System32\dxgi.dll'
)

$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot\Add-VMGpuPartitionAdapterFiles.psm1"

# Paths relative to the Windows directory
$SystemFiles = @(
    'System32\drivers\dxgkrnl.sys',
    'System32\drivers\dxgmms1.sys',
    'System32\drivers\dxgmms2.sys'
) + $ExtraSystemFiles

# Files whose host vs guest versions are printed at the end as a sanity check
$VersionCheckFiles = $SystemFiles + @('System32\nvapi64.dll', 'System32\nvcuda.dll', 'System32\nvEncodeAPI64.dll')

function Get-Ver($Path) {
    if (Test-Path $Path) { (Get-Item $Path).VersionInfo.FileVersion -replace ' .*$', '' } else { '(missing)' }
}

# Offline guest files can be TrustedInstaller-owned or have restrictive ACLs. Take ownership and give
# Administrators full control. Accepts wildcards.
function Grant-GuestAccess {
    param([string]$Path, [switch]$Recurse)
    $ErrorActionPreference = 'Continue'   # takeown/icacls print "no match" to stderr; that's harmless
    if ($Recurse) {
        # icacls /setowner avoids takeown's localized "Y/N" prompt on directories
        icacls.exe $Path /setowner "*S-1-5-32-544" /t /c 2>$null | Out-Null
        icacls.exe $Path /grant "*S-1-5-32-544:F" /t /c 2>$null | Out-Null
    }
    else {
        takeown.exe /f $Path 2>$null | Out-Null
        icacls.exe $Path /grant "*S-1-5-32-544:F" 2>$null | Out-Null
    }
}

function Remove-StaleGuestNvidiaFiles {
    param([string]$DriveLetter)
    $win = "${DriveLetter}:\Windows"

    $store = "$win\System32\HostDriverStore\FileRepository"
    if (Test-Path $store) {
        "Removing stale NVIDIA driver folders from guest HostDriverStore..."
        Get-ChildItem $store -Directory -Filter 'nv_dispi*' | Remove-Item -Recurse -Force
    }

    "Removing stale NVIDIA files from guest System32/SysWOW64 so the module copies fresh ones..."
    foreach ($dir in 'System32', 'SysWOW64') {
        Grant-GuestAccess "$win\$dir\nv*"
        Get-ChildItem "$win\$dir" -Filter 'nv*' -File -ErrorAction SilentlyContinue |
            Remove-Item -Force -ErrorAction Continue
    }
    $mcu = "$win\System32\mcu.exe"
    if (Test-Path $mcu) {
        Grant-GuestAccess $mcu
        Remove-Item $mcu -Force -ErrorAction Continue
    }
}

function Copy-GuestSystemFiles {
    param([string]$DriveLetter)

    $hostWin  = $env:SystemRoot
    $guestWin = "${DriveLetter}:\Windows"

    $hostOs  = [version](Get-Item "$hostWin\System32\ntoskrnl.exe").VersionInfo.ProductVersion
    $guestOs = [version](Get-Item "$guestWin\System32\ntoskrnl.exe").VersionInfo.ProductVersion
    "Host OS: $hostOs | Guest OS: $guestOs"

    if ($hostOs.Build -ne $guestOs.Build -and -not $IgnoreBuildMismatch) {
        Write-Warning "Host and guest are on different Windows builds ($($hostOs.Build) vs $($guestOs.Build)). Skipping system file copy. Update the guest to the same build, or use -IgnoreBuildMismatch."
        return
    }

    $backup = Join-Path $PSScriptRoot "SystemFileBackup\$VMName\$(Get-Date -Format yyyyMMdd-HHmmss)"

    foreach ($rel in $SystemFiles) {
        $src = Join-Path $hostWin $rel
        $dst = Join-Path $guestWin $rel

        if (-not (Test-Path $src)) { Write-Warning "Not on host, skipping: $rel"; continue }

        if ((Test-Path $dst) -and ((Get-FileHash $src).Hash -eq (Get-FileHash $dst).Hash)) {
            "Already current: $rel"
            continue
        }

        if (Test-Path $dst) {
            $bdir = Join-Path $backup (Split-Path $rel -Parent)
            New-Item -ItemType Directory -Path $bdir -Force | Out-Null
            Copy-Item $dst $bdir -Force
            Grant-GuestAccess $dst
        }

        Copy-Item $src $dst -Force
        "Copied: $rel"
    }
}

$copyErrors = @()

$VM  = Get-VM -VMName $VMName
$VHD = Get-VHD -VMId $VM.VMId

If ($VM.State -eq "Running") { [bool]$state_was_running = $true }

if ($VM.State -ne "Off") {
    "Attemping to shutdown VM..."
    Stop-VM -Name $VMName -Force
}

While ((Get-VM -VMName $VMName).State -ne "Off") {
    Start-Sleep -s 3
    "Waiting for VM to shutdown - make sure there are no unsaved documents..."
}

"Mounting Drive..."
$disk = Mount-VHD -Path $VHD.Path -PassThru | Get-Disk
try {
    $DriveLetter = ($disk | Get-Partition | Get-Volume | Where-Object { $_.DriveLetter } | ForEach-Object DriveLetter) | Select-Object -First 1

    # Windows 11 24H2 sometimes mounts the volume without a drive letter
    if (-not $DriveLetter) {
        $part = $disk | Get-Partition | Sort-Object Size -Descending | Select-Object -First 1
        $part | Add-PartitionAccessPath -AssignDriveLetter
        $DriveLetter = ($part | Get-Partition).DriveLetter
    }
    "Guest volume mounted as ${DriveLetter}:"

    if ($CleanStaleDriverStore) { Remove-StaleGuestNvidiaFiles -DriveLetter $DriveLetter }

    # The module aborts at the first "access denied", so unblock the folders it is known to hit up front
    # (WSL libs and the NVIDIA license file) instead of fixing them one file per retry.
    foreach ($d in 'System32\lxss', 'System32\drivers\NVIDIA Corporation') {
        $p = "${DriveLetter}:\Windows\$d"
        if (Test-Path $p) { "Granting access on $d ..."; Grant-GuestAccess $p -Recurse }
    }

    "Copying GPU Files - this could take a while..."
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'   # don't abort mid-copy; failures are collected and reported below
    $granted = @{}
    for ($attempt = 1; $attempt -le 40; $attempt++) {
        $Error.Clear()
        try { Add-VMGPUPartitionAdapterFiles -hostname $Hostname -DriveLetter $DriveLetter -GPUName $GPUName } catch { }

        # Find "access denied" copies. The error's target is the host-side source path; the matching
        # guest file has the same path under the guest's drive letter.
        $targets = @($Error | Where-Object {
                ($_.Exception -is [System.UnauthorizedAccessException] -or $_.CategoryInfo.Category -eq 'PermissionDenied') -and
                $_.CategoryInfo.TargetName
            } | ForEach-Object { $_.CategoryInfo.TargetName -replace '^[A-Za-z]:', "${DriveLetter}:" } | Select-Object -Unique)

        $new = @($targets | Where-Object { -not $granted.ContainsKey($_) })
        if ($new.Count -eq 0) { break }   # nothing denied, or nothing new we can fix
        foreach ($t in $new) {
            "Access denied on $t - taking ownership and retrying (attempt $attempt)..."
            Grant-GuestAccess $t
            $granted[$t] = $true
        }
    }
    $ErrorActionPreference = $prevEAP

    $copyErrors = @($Error)
    if ($copyErrors.Count -gt 0) {
        Write-Warning "$($copyErrors.Count) error(s) remained after the last copy attempt:"
        $copyErrors | ForEach-Object { Write-Warning $_.Exception.Message }
    }

    if (-not $SkipSystemFiles) {
        "Syncing dxgkrnl and related system files..."
        Copy-GuestSystemFiles -DriveLetter $DriveLetter
    }

    "`nVersion check (host vs guest):"
    $VersionCheckFiles | ForEach-Object {
        $h = Get-Ver (Join-Path $env:SystemRoot $_)
        $g = Get-Ver "${DriveLetter}:\Windows\$_"
        [pscustomobject]@{ File = $_; Host = $h; Guest = $g; Match = ($h -eq $g) }
    } | Format-Table -AutoSize
}
finally {
    "Dismounting Drive..."
    Dismount-VHD -Path $VHD.Path
}

If ($copyErrors.Count -gt 0) {
    Write-Warning "GPU file copy had errors, so the VM was NOT started. Fix the errors above and re-run before booting it."
}
elseif ($state_was_running) {
    "Previous State was running so starting VM..."
    Start-VM $VMName
}

"Done..."
