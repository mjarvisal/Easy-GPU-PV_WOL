<#
.SYNOPSIS
    Fixes the GPU-PV partition resource allocation problem found while troubleshooting
    Easy-GPU-PV / GPU-PV crashes (apps crashing during load, e.g. 3DMark crashing while
    loading a benchmark).

.DESCRIPTION
    Add-VMGpuPartitionAdapter can leave a VM's GPU partition adapter with a near-empty
    Compute allocation (CurrentPartitionCompute: 0) even though VRAM/Encode/Decode look
    fully allocated. Anything that leans on GPU compute during initialization - shader
    compilation, DirectCompute passes, benchmark loading screens - can then crash.

    This script explicitly sets generous VRAM/Encode/Decode/Compute partition values on
    the adapter, using the values from the community GPU-PV setup guides. The VM must be
    powered off for Set-VMGpuPartitionAdapter to take effect, so this script will shut it
    down first if it's running, and restart it afterwards.

    This is a companion fix to the separately-patched Update-VMGpuPartitionDriver.ps1 and
    Add-VMGpuPartitionAdapterFiles.psm1, which addressed a different problem (the VHD
    mounting without a drive letter on Windows 11 24H2 hosts, causing driver files to
    silently fail to copy into the VM).

.PARAMETER VMName
    Name of the VM to patch.

.PARAMETER StartAfter
    Start the VM after applying the fix, even if it wasn't running beforehand.

.EXAMPLE
    .\Fix-VMGpuPartitionAllocation.ps1 -VMName "GamingPC"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$VMName,

    [switch]$StartAfter
)

$ErrorActionPreference = "Stop"

# Min=Max=Optimal at this scale reliably grants a full, generous allocation across all
# four partition categories. Units here are Hyper-V's internal relative-share scale, not
# literal bytes - these are the same values used across the community GPU-PV setup guides.
$MinShare = 80000000
$FullShare = 100000000000

Write-Host "INFO   : Looking up VM '$VMName'..."
$VM = Get-VM -Name $VMName

$WasRunning = $VM.State -eq 'Running'

if ($WasRunning) {
    Write-Host "INFO   : VM is running - shutting down (required for Set-VMGpuPartitionAdapter)..."
    Stop-VM -Name $VMName -Force

    $timeoutSeconds = 60
    $elapsed = 0
    while ((Get-VM -Name $VMName).State -ne 'Off' -and $elapsed -lt $timeoutSeconds) {
        Start-Sleep -Seconds 2
        $elapsed += 2
    }
    if ((Get-VM -Name $VMName).State -ne 'Off') {
        Throw "FATAL  : VM did not reach 'Off' state within $timeoutSeconds seconds. Aborting before touching the GPU partition adapter."
    }
}

Write-Host "INFO   : GPU partition allocation BEFORE fix:"
Get-VMGpuPartitionAdapter -VMName $VMName |
    Format-List CurrentPartitionVRAM, CurrentPartitionEncode, CurrentPartitionDecode, CurrentPartitionCompute, `
                MinPartitionVRAM, MaxPartitionVRAM, OptimalPartitionVRAM, `
                MinPartitionCompute, MaxPartitionCompute, OptimalPartitionCompute

Write-Host "INFO   : Applying generous VRAM / Encode / Decode / Compute partition values..."
Set-VMGpuPartitionAdapter -VMName $VMName `
    -MinPartitionVRAM $MinShare -MaxPartitionVRAM $FullShare -OptimalPartitionVRAM $FullShare `
    -MinPartitionEncode $MinShare -MaxPartitionEncode $FullShare -OptimalPartitionEncode $FullShare `
    -MinPartitionDecode $MinShare -MaxPartitionDecode $FullShare -OptimalPartitionDecode $FullShare `
    -MinPartitionCompute $MinShare -MaxPartitionCompute $FullShare -OptimalPartitionCompute $FullShare

# GPU-PV is incompatible with checkpoints per Microsoft's own setup docs - make sure
# they're off so a stray checkpoint doesn't silently break the GPU partition later.
Set-VM -CheckpointType Disabled -VMName $VMName

Write-Host "INFO   : GPU partition allocation AFTER fix:"
Get-VMGpuPartitionAdapter -VMName $VMName |
    Format-List CurrentPartitionVRAM, CurrentPartitionEncode, CurrentPartitionDecode, CurrentPartitionCompute, `
                MinPartitionVRAM, MaxPartitionVRAM, OptimalPartitionVRAM, `
                MinPartitionCompute, MaxPartitionCompute, OptimalPartitionCompute

if ($StartAfter -or $WasRunning) {
    Write-Host "INFO   : Starting VM '$VMName'..."
    Start-VM -Name $VMName
}

Write-Host "Done..."
