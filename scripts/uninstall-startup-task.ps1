#Requires -Version 5.1
#Requires -RunAsAdministrator

param(
    [string]$TaskName = "TailscaleWolRelay",
    [string]$InstallDirectory = (Join-Path $env:ProgramData "TailscaleWolRelay"),
    [string]$FirewallRuleName = "TailscaleWolRelay-HTTP",
    [switch]$RemoveData
)

$ErrorActionPreference = "Stop"

$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue

if ($null -eq $task) {
    Write-Host "Scheduled task '$TaskName' was not found."
}
else {
    if ($task.State -in @("Running", "Queued")) {
        Stop-ScheduledTask -TaskName $TaskName

        $deadline = [DateTime]::UtcNow.AddSeconds(15)
        do {
            Start-Sleep -Milliseconds 250
            $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        }
        while ($null -ne $task -and $task.State -in @("Running", "Queued") -and [DateTime]::UtcNow -lt $deadline)

        if ($null -ne $task -and $task.State -in @("Running", "Queued")) {
            throw "Scheduled task '$TaskName' did not stop within 15 seconds."
        }
    }

    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Host "Scheduled task '$TaskName' removed."
}

$firewallRule = Get-NetFirewallRule -Name $FirewallRuleName -ErrorAction SilentlyContinue

if ($null -ne $firewallRule) {
    Remove-NetFirewallRule -Name $FirewallRuleName
    Write-Host "Firewall rule '$FirewallRuleName' removed."
}
else {
    Write-Host "Firewall rule '$FirewallRuleName' was not found."
}

if (-not $RemoveData) {
    if (Test-Path -LiteralPath $InstallDirectory) {
        Write-Host "Runtime files and logs were preserved at '$InstallDirectory'."
        Write-Host "Run this script with -RemoveData to delete them."
    }

    return
}

$programDataPath = [System.IO.Path]::GetFullPath($env:ProgramData).TrimEnd("\")
$fullInstallPath = [System.IO.Path]::GetFullPath($InstallDirectory).TrimEnd("\")
$requiredPrefix = $programDataPath + "\"

if (-not $fullInstallPath.StartsWith($requiredPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to remove data outside ProgramData: $fullInstallPath"
}

if (Test-Path -LiteralPath $fullInstallPath) {
    $installItem = Get-Item -LiteralPath $fullInstallPath -Force

    if (($installItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Refusing to recursively remove a reparse point: $fullInstallPath"
    }

    Remove-Item -LiteralPath $fullInstallPath -Recurse -Force
    Write-Host "Runtime files and logs removed from '$fullInstallPath'."
}
