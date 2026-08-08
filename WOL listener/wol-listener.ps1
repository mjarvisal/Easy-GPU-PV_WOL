<#
.SYNOPSIS
    Wake-on-LAN listener for Hyper-V guests.

.DESCRIPTION
    Hyper-V VMs have no native WOL support: when a VM is Off or Saved, its
    virtual NIC doesn't exist on the wire, so nothing can "hear" a magic
    packet sent directly to it. This script runs on the Hyper-V HOST,
    listens on the physical LAN for standard WOL magic packets, matches
    the target MAC against your VMs' virtual NIC MACs, and calls Start-VM
    (which transparently resumes from Saved state or cold-boots from Off).

.NOTES
    - Must run with Hyper-V admin rights (SYSTEM via Scheduled Task is easiest).
    - Binding UDP ports 7/9 does NOT require elevation on Windows.
    - Rebuilds the MAC->VM lookup on every packet, so it "just works" if you
      add/rename VMs without restarting the listener.
#>

param(
    [int[]]$Ports = @(7, 9),
    [int]$PollIntervalMs = 50
)

$LogPath = Join-Path $PSScriptRoot "wol-listener.log"

function Write-Log {
    param([string]$Message)
    $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
    Add-Content -Path $LogPath -Value $line
    Write-Host $line
}

function Get-VmMacTable {
    # MAC (no separators, uppercase) -> VM name
    $table = @{}
    foreach ($vm in Get-VM) {
        foreach ($nic in (Get-VMNetworkAdapter -VMName $vm.Name)) {
            if ($nic.MacAddress) {
                $table[$nic.MacAddress.ToUpper()] = $vm.Name
            }
        }
    }
    return $table
}

function Parse-MagicPacket {
    param([byte[]]$Bytes)
    # 6 x 0xFF sync stream, then the target MAC repeated 16 times = 102 bytes min
    if ($Bytes.Length -lt 102) { return $null }
    for ($i = 0; $i -lt 6; $i++) {
        if ($Bytes[$i] -ne 0xFF) { return $null }
    }
    $mac = $Bytes[6..11]
    for ($rep = 1; $rep -lt 16; $rep++) {
        $offset = 6 + ($rep * 6)
        for ($b = 0; $b -lt 6; $b++) {
            if ($Bytes[$offset + $b] -ne $mac[$b]) { return $null }
        }
    }
    return ($mac | ForEach-Object { $_.ToString("X2") }) -join ""
}

Write-Log "=== WOL listener starting (ports: $($Ports -join ', ')) ==="

$sockets = @()
foreach ($port in $Ports) {
    try {
        $udp = New-Object System.Net.Sockets.UdpClient($port)
        $sockets += [PSCustomObject]@{ Client = $udp; Port = $port }
        Write-Log "Bound UDP port $port"
    } catch {
        Write-Log "WARNING: could not bind port $port - $_"
    }
}

if ($sockets.Count -eq 0) {
    Write-Log "FATAL: no ports bound, exiting"
    exit 1
}

$anyEndpoint = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)

while ($true) {
    foreach ($sock in $sockets) {
        try {
            if ($sock.Client.Available -gt 0) {
                $bytes = $sock.Client.Receive([ref]$anyEndpoint)
                $mac = Parse-MagicPacket -Bytes $bytes
                if ($mac) {
                    Write-Log "Magic packet for MAC $mac (port $($sock.Port), from $($anyEndpoint.Address))"
                    $macTable = Get-VmMacTable
                    if ($macTable.ContainsKey($mac)) {
                        $vmName = $macTable[$mac]
                        $state = (Get-VM -Name $vmName).State
                        Write-Log "Matched VM '$vmName' (state: $state)"
                        if ($state -in @('Off', 'Saved', 'Paused')) {
                            try {
                                if ($state -eq 'Paused') {
                                    Resume-VM -Name $vmName -ErrorAction Stop
                                    Write-Log "Resume-VM issued for '$vmName'"
                                } else {
                                    Start-VM -Name $vmName -ErrorAction Stop
                                    Write-Log "Start-VM issued for '$vmName'"
                                }
                            } catch {
                                Write-Log "ERROR starting '$vmName': $_"
                            }
                        } else {
                            Write-Log "'$vmName' already in state '$state' - ignoring"
                        }
                    } else {
                        Write-Log "No VM NIC matches MAC $mac"
                    }
                }
            }
        } catch {
            Write-Log "Socket error on port $($sock.Port): $_"
        }
    }
    Start-Sleep -Milliseconds $PollIntervalMs
}
