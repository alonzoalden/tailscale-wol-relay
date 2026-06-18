param(
    [string]$TaskName = "TailscaleWolRelay",
    [string]$ScriptPath = (Join-Path (Split-Path -Parent $PSScriptRoot) "wake-server.ps1")
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $ScriptPath)) {
    throw "Could not find wake-server.ps1 at: $ScriptPath"
}

$resolvedScriptPath = (Resolve-Path -LiteralPath $ScriptPath).ProviderPath
$currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name

$action = New-ScheduledTaskAction `
    -Execute "powershell.exe" `
    -Argument "-ExecutionPolicy Bypass -File `"$resolvedScriptPath`""

$trigger = New-ScheduledTaskTrigger -AtLogOn
# ScheduledTasks uses RunLevel enum values Limited or Highest; Limited is the normal current-user task.
$principal = New-ScheduledTaskPrincipal `
    -UserId $currentUser `
    -LogonType Interactive `
    -RunLevel Limited

$description = "Runs tailscale-wol-relay at user logon."

Register-ScheduledTask `
    -TaskName $TaskName `
    -Action $action `
    -Trigger $trigger `
    -Principal $principal `
    -Description $description `
    -Force | Out-Null

Write-Host "Scheduled task '$TaskName' installed for $currentUser."
Write-Host "Action: powershell.exe -ExecutionPolicy Bypass -File `"$resolvedScriptPath`""
Write-Host "Run level: Limited"
Write-Host "Admin is usually not required for this current-user logon task."
