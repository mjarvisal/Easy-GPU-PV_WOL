$wolScript = Join-Path $PSScriptRoot "wol-listener.ps1"
$wolArguments = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f $wolScript
$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $wolArguments
$trigger = New-ScheduledTaskTrigger -AtStartup
$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
Register-ScheduledTask -TaskName "HyperV-WOL-Listener" -Action $action -Trigger $trigger -Principal $principal

$suspendScript = Join-Path $PSScriptRoot "suspend-listener.ps1"
$suspendArguments = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f $suspendScript
$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $suspendArguments
$trigger = New-ScheduledTaskTrigger -AtStartup
$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
Register-ScheduledTask -TaskName "HyperV-Suspend-Listener" -Action $action -Trigger $trigger -Principal $principal