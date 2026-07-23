#Requires -Version 5.1
#Requires -RunAsAdministrator

param(
    [string]$TaskName = "TailscaleWolRelay",
    [string]$ScriptPath = (Join-Path (Split-Path -Parent $PSScriptRoot) "wake-server.ps1"),
    [string]$InstallDirectory = (Join-Path $env:ProgramData "TailscaleWolRelay"),
    [string]$FirewallRuleName = "TailscaleWolRelay-HTTP"
)

$ErrorActionPreference = "Stop"

function Get-ConfigValueFromFile {
    param(
        [string]$Path,
        [string]$Name,
        [string]$DefaultValue = ""
    )

    $result = $DefaultValue

    foreach ($line in Get-Content -LiteralPath $Path) {
        $trimmed = $line.Trim()

        if ($trimmed -eq "" -or $trimmed.StartsWith("#")) {
            continue
        }

        $parts = $trimmed -split "=", 2

        if ($parts.Count -eq 2 -and $parts[0].Trim() -eq $Name) {
            $result = $parts[1].Trim()

            if ($result.Length -ge 2) {
                $first = $result.Substring(0, 1)
                $last = $result.Substring($result.Length - 1, 1)

                if (($first -eq '"' -and $last -eq '"') -or ($first -eq "'" -and $last -eq "'")) {
                    $result = $result.Substring(1, $result.Length - 2)
                }
            }
        }
    }

    return [string]$result
}

function Get-HttpPortFromConfig {
    param([string]$Path)

    $portText = Get-ConfigValueFromFile -Path $Path -Name "HTTP_PORT" -DefaultValue "8787"

    $port = 0
    if (-not [int]::TryParse($portText, [ref]$port) -or $port -lt 1 -or $port -gt 65535) {
        throw "HTTP_PORT in '$Path' must be a number between 1 and 65535."
    }

    return $port
}

function Assert-OptionalIPv4Config {
    param(
        [string]$Path,
        [string]$Name
    )

    $value = Get-ConfigValueFromFile -Path $Path -Name $Name

    if ([string]::IsNullOrWhiteSpace($value)) {
        return
    }

    $address = $null
    if (-not [System.Net.IPAddress]::TryParse($value, [ref]$address) -or $address.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
        throw "$Name in '$Path' must be a valid IPv4 address when set."
    }
}

function Assert-RelayConfig {
    param([string]$Path)

    $targetMac = Get-ConfigValueFromFile -Path $Path -Name "TARGET_MAC"
    $cleanMac = $targetMac -replace "[:-]", ""

    if ($cleanMac -notmatch "^[0-9A-Fa-f]{12}$") {
        throw "TARGET_MAC in '$Path' must use the format AA:BB:CC:DD:EE:FF."
    }

    if ([string]::Equals($cleanMac, "AABBCCDDEEFF", [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "TARGET_MAC in '$Path' still contains the example value. Replace it with the target device's wired network adapter MAC."
    }

    $wakeKey = Get-ConfigValueFromFile -Path $Path -Name "WAKE_KEY"
    if ([string]::Equals($wakeKey, "change-me", [System.StringComparison]::Ordinal)) {
        throw "WAKE_KEY in '$Path' still contains the example value. Replace it with a private key before installing the relay."
    }

    [void](Get-HttpPortFromConfig -Path $Path)
    Assert-OptionalIPv4Config -Path $Path -Name "TARGET_IP"
    Assert-OptionalIPv4Config -Path $Path -Name "MANUAL_BROADCAST_ADDRESS"
}

function Get-TailscaleCliPath {
    $candidates = New-Object System.Collections.Generic.List[string]
    $pathCommand = Get-Command "tailscale.exe" -ErrorAction SilentlyContinue

    if ($null -ne $pathCommand -and -not [string]::IsNullOrWhiteSpace($pathCommand.Source)) {
        $candidates.Add($pathCommand.Source)
    }

    if (-not [string]::IsNullOrWhiteSpace($env:ProgramFiles)) {
        $candidates.Add((Join-Path $env:ProgramFiles "Tailscale\tailscale.exe"))
    }

    if (-not [string]::IsNullOrWhiteSpace(${env:ProgramFiles(x86)})) {
        $candidates.Add((Join-Path ${env:ProgramFiles(x86)} "Tailscale\tailscale.exe"))
    }

    foreach ($candidate in $candidates | Select-Object -Unique) {
        if (Test-Path -LiteralPath $candidate) {
            return (Resolve-Path -LiteralPath $candidate).ProviderPath
        }
    }

    throw "Could not find tailscale.exe. Install Tailscale for Windows before installing the relay."
}

function Enable-TailscaleUnattendedMode {
    $tailscaleService = Get-Service -Name "Tailscale" -ErrorAction SilentlyContinue

    if ($null -eq $tailscaleService) {
        throw "The Tailscale Windows service was not found. Install Tailscale before installing the relay."
    }

    Set-Service -Name "Tailscale" -StartupType Automatic

    if ($tailscaleService.Status -ne "Running") {
        Start-Service -Name "Tailscale"
        $tailscaleService.WaitForStatus(
            [System.ServiceProcess.ServiceControllerStatus]::Running,
            (New-TimeSpan -Seconds 15)
        )
    }

    $tailscaleCli = Get-TailscaleCliPath
    $unattendedOutput = & $tailscaleCli set --unattended=true 2>&1

    if ($LASTEXITCODE -ne 0) {
        $setError = $unattendedOutput -join " "
        $unattendedOutput = & $tailscaleCli up --unattended=true 2>&1

        if ($LASTEXITCODE -ne 0) {
            throw "Could not enable Tailscale unattended mode. 'tailscale set' failed with: $setError. 'tailscale up' failed with: $($unattendedOutput -join ' ')"
        }
    }

    $tailscaleIpOutput = & $tailscaleCli ip -4 2>&1

    if ($LASTEXITCODE -ne 0) {
        throw "Tailscale unattended mode was enabled, but the relay is not connected: $($tailscaleIpOutput -join ' ')"
    }

    $tailscaleIp = $tailscaleIpOutput | Where-Object { $_ -match "^100\." } | Select-Object -First 1

    if ([string]::IsNullOrWhiteSpace([string]$tailscaleIp)) {
        throw "Tailscale did not report a 100.x IPv4 address after unattended mode was enabled. Sign in to Tailscale, then run this installer again."
    }

    return [string]$tailscaleIp
}

function Wait-RelayHealth {
    param(
        [string]$Url,
        [int]$TimeoutSeconds = 30
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $lastError = "No response received."

    do {
        try {
            return Invoke-WebRequest -UseBasicParsing -Uri $Url -TimeoutSec 3
        }
        catch {
            $lastError = $_.Exception.Message
        }

        if ([DateTime]::UtcNow -lt $deadline) {
            Start-Sleep -Seconds 1
        }
    }
    while ([DateTime]::UtcNow -lt $deadline)

    throw "Relay health check did not succeed within $TimeoutSeconds seconds. Last request error: $lastError"
}

function Stop-ExistingRelayTask {
    param(
        [string]$Name,
        [int]$TimeoutSeconds = 15
    )

    $task = Get-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue

    if ($null -eq $task -or $task.State -notin @("Running", "Queued")) {
        return
    }

    Write-Host "Stopping the existing '$Name' task..."
    Stop-ScheduledTask -TaskName $Name
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)

    do {
        Start-Sleep -Milliseconds 250
        $task = Get-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue

        if ($null -eq $task -or $task.State -notin @("Running", "Queued")) {
            return
        }
    }
    while ([DateTime]::UtcNow -lt $deadline)

    throw "The existing '$Name' task did not stop within $TimeoutSeconds seconds."
}

function Wait-TcpPortAvailable {
    param(
        [int]$Port,
        [int]$TimeoutSeconds = 10
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)

    do {
        $listener = Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue

        if ($null -eq $listener) {
            return
        }

        Start-Sleep -Milliseconds 250
    }
    while ([DateTime]::UtcNow -lt $deadline)

    throw "TCP port $Port is already in use. Stop the existing relay or other listener, or restart Windows, then run this installer again."
}

if (-not (Test-Path -LiteralPath $ScriptPath)) {
    throw "Could not find wake-server.ps1 at: $ScriptPath"
}

$resolvedScriptPath = (Resolve-Path -LiteralPath $ScriptPath).ProviderPath
$sourceDirectory = Split-Path -Parent $resolvedScriptPath
$sourceConfigPath = Join-Path $sourceDirectory ".env"

if (-not (Test-Path -LiteralPath $sourceConfigPath)) {
    throw "Could not find .env at: $sourceConfigPath. Copy .env.example to .env and configure it before installing."
}

Assert-RelayConfig -Path $sourceConfigPath
$httpPort = Get-HttpPortFromConfig -Path $sourceConfigPath
$tailscaleIp = Enable-TailscaleUnattendedMode
Stop-ExistingRelayTask -Name $TaskName
Wait-TcpPortAvailable -Port $httpPort

$programDataPath = [System.IO.Path]::GetFullPath($env:ProgramData).TrimEnd("\")
$fullInstallPath = [System.IO.Path]::GetFullPath($InstallDirectory).TrimEnd("\")
$requiredInstallPrefix = $programDataPath + "\"

if (-not $fullInstallPath.StartsWith($requiredInstallPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "InstallDirectory must be a child of ProgramData: $fullInstallPath"
}

if (Test-Path -LiteralPath $fullInstallPath) {
    $installItem = Get-Item -LiteralPath $fullInstallPath -Force

    if (-not $installItem.PSIsContainer) {
        throw "InstallDirectory exists but is not a directory: $fullInstallPath"
    }

    if (($installItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Refusing to install through a reparse point: $fullInstallPath"
    }
}

New-Item -ItemType Directory -Path $InstallDirectory -Force | Out-Null
$resolvedInstallDirectory = (Resolve-Path -LiteralPath $InstallDirectory).ProviderPath

# The task runs as SYSTEM. Keep its script and secret-bearing .env in a directory
# that standard users cannot modify, otherwise the task would create a privilege-escalation path.
$aclOutput = & icacls.exe `
    $resolvedInstallDirectory `
    /inheritance:r `
    /grant:r `
    "*S-1-5-18:(OI)(CI)F" `
    "*S-1-5-32-544:(OI)(CI)F" 2>&1

if ($LASTEXITCODE -ne 0) {
    throw "Could not secure '$resolvedInstallDirectory': $($aclOutput -join ' ')"
}

$installedScriptPath = Join-Path $resolvedInstallDirectory "wake-server.ps1"
$installedConfigPath = Join-Path $resolvedInstallDirectory ".env"

if (-not [string]::Equals($resolvedScriptPath, $installedScriptPath, [System.StringComparison]::OrdinalIgnoreCase)) {
    Copy-Item -LiteralPath $resolvedScriptPath -Destination $installedScriptPath -Force
}

if (-not [string]::Equals($sourceConfigPath, $installedConfigPath, [System.StringComparison]::OrdinalIgnoreCase)) {
    Copy-Item -LiteralPath $sourceConfigPath -Destination $installedConfigPath -Force
}

$windowsPowerShell = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"

if (-not (Test-Path -LiteralPath $windowsPowerShell)) {
    throw "Could not find Windows PowerShell at: $windowsPowerShell"
}

$action = New-ScheduledTaskAction `
    -Execute $windowsPowerShell `
    -Argument "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$installedScriptPath`"" `
    -WorkingDirectory $resolvedInstallDirectory

$triggers = @(
    (New-ScheduledTaskTrigger -AtStartup),
    (New-ScheduledTaskTrigger -AtLogOn)
)

$principal = New-ScheduledTaskPrincipal `
    -UserId "SYSTEM" `
    -LogonType ServiceAccount `
    -RunLevel Highest

$settings = New-ScheduledTaskSettingsSet `
    -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -RestartCount 999 `
    -RestartInterval (New-TimeSpan -Minutes 1) `
    -StartWhenAvailable `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -MultipleInstances IgnoreNew

$description = "Runs the Tailscale Wake-on-LAN relay at system startup with automatic recovery."

Register-ScheduledTask `
    -TaskName $TaskName `
    -Action $action `
    -Trigger $triggers `
    -Principal $principal `
    -Settings $settings `
    -Description $description `
    -Force | Out-Null

$existingFirewallRule = Get-NetFirewallRule -Name $FirewallRuleName -ErrorAction SilentlyContinue

if ($null -ne $existingFirewallRule) {
    Remove-NetFirewallRule -Name $FirewallRuleName
}

New-NetFirewallRule `
    -Name $FirewallRuleName `
    -DisplayName "Tailscale WOL Relay (TCP $httpPort)" `
    -Description "Allows Tailscale clients to reach the Wake-on-LAN relay." `
    -Direction Inbound `
    -Action Allow `
    -Protocol TCP `
    -LocalPort $httpPort `
    -RemoteAddress "100.64.0.0/10" `
    -Profile Any | Out-Null

Start-ScheduledTask -TaskName $TaskName
$healthUrl = "http://localhost:$httpPort/health"

try {
    $healthResponse = Wait-RelayHealth -Url $healthUrl -TimeoutSeconds 30
}
catch {
    $task = Get-ScheduledTask -TaskName $TaskName
    $taskInfo = Get-ScheduledTaskInfo -TaskName $TaskName
    $logPath = Join-Path $resolvedInstallDirectory "wake-server.log"
    $recentLog = "No relay log was created."

    if (Test-Path -LiteralPath $logPath) {
        $recentLog = (Get-Content -LiteralPath $logPath -Tail 10) -join " | "
    }

    throw "$($_.Exception.Message) Task state: $($task.State); last result: $($taskInfo.LastTaskResult). Recent log: $recentLog"
}

Write-Host "Scheduled task '$TaskName' installed and started successfully."
Write-Host "Identity: SYSTEM (runs before user logon)"
Write-Host "Runtime: unlimited; restarts after failures"
Write-Host "Tailscale: unattended, Automatic service, IPv4 $tailscaleIp"
Write-Host "Installed files: $resolvedInstallDirectory"
Write-Host "Firewall: TCP $httpPort from Tailscale addresses (100.64.0.0/10)"
Write-Host "Health check: HTTP $($healthResponse.StatusCode) from $healthUrl"
Write-Host "Re-run this installer after changing wake-server.ps1 or .env."
