<#
.SYNOPSIS
    Runs inside the GUEST. Called from Sunshine's "undo" prep-cmd on
    disconnect. Signals the Hyper-V host to suspend this VM.
#>

param(
    [string]$HostIP = "192.168.50.128",   # <-- your Hyper-V host's LAN IP, not the VM's own IP
    [int]$Port = 5900,
    [string]$Secret = "changeme-shared-secret"  # must match suspend-listener.ps1 on the host
)

try {
    $client = New-Object System.Net.Sockets.TcpClient
    $client.Connect($HostIP, $Port)
    $stream = $client.GetStream()
    $bytes = [System.Text.Encoding]::ASCII.GetBytes("SUSPEND:$Secret")
    $stream.Write($bytes, 0, $bytes.Length)
    $stream.Close()
    $client.Close()
} catch {
    # Fail silently - we don't want a network hiccup to hang the Sunshine
    # prep-cmd pipeline or block the client from disconnecting cleanly.
}
