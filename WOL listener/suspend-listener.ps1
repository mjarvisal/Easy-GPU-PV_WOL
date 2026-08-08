<#
.SYNOPSIS
    Suspends a Hyper-V VM on request from inside the guest.

.DESCRIPTION
    Companion to wol-listener.ps1, running the opposite direction. Sunshine
    (inside the guest) triggers this via its "undo" prep-cmd on disconnect;
    this script listens on the host for that signal and calls Suspend-VM
    (or Save-VM) since the guest itself has no permission to manage the
    Hyper-V VM it's running inside of.

.NOTES
    Run as SYSTEM/Administrator, e.g. as a Scheduled Task at startup,
    alongside wol-listener.ps1.
#>

param(
    [int]$Port = 5900,
    [string]$Secret = "changeme-shared-secret",
    [string]$VMName = "GamingPC",
    [ValidateSet('Suspend', 'Save')]
    [string]$Mode = "Suspend"
)

$LogPath = Join-Path $PSScriptRoot "suspend-listener.log"

function Write-Log {
    param([string]$Message)
    $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
    Add-Content -Path $LogPath -Value $line
    Write-Host $line
}

Write-Log "=== Suspend listener starting on TCP port $Port (VM: $VMName, mode: $Mode) ==="

$listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Any, $Port)
$listener.Start()

while ($true) {
    $client = $listener.AcceptTcpClient()
    $remoteIP = ([System.Net.IPEndPoint]$client.Client.RemoteEndPoint).Address.ToString()

    try {
        $stream = $client.GetStream()
        $buffer = New-Object byte[] 256
        $bytesRead = $stream.Read($buffer, 0, $buffer.Length)
        $msg = [System.Text.Encoding]::ASCII.GetString($buffer, 0, $bytesRead).Trim()

        if ($msg -ne "SUSPEND:$Secret") {
            Write-Log "Rejected message from $remoteIP (bad/missing secret)"
            continue
        }

        $state = (Get-VM -Name $VMName).State
        if ($state -ne 'Running') {
            Write-Log "'$VMName' not Running (state: $state) - ignoring request from $remoteIP"
            continue
        }

        if ($Mode -eq 'Suspend') {
            Suspend-VM -Name $VMName
        } else {
            Save-VM -Name $VMName
        }
        Write-Log "$Mode-VM issued for '$VMName' (requested by $remoteIP)"

    } catch {
        Write-Log "Error handling connection from $remoteIP : $_"
    } finally {
        $client.Close()
    }
}
