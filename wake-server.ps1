$ErrorActionPreference = "Stop"

$ConfigPath = Join-Path $PSScriptRoot ".env"
$LogPath = Join-Path $PSScriptRoot "wake-server.log"

function Read-DotEnv {
    param([string]$Path)

    $values = @{}

    if (-not (Test-Path -LiteralPath $Path)) {
        return $values
    }

    $lines = Get-Content -LiteralPath $Path

    foreach ($line in $lines) {
        $trimmed = $line.Trim()

        if ($trimmed -eq "" -or $trimmed.StartsWith("#")) {
            continue
        }

        $parts = $trimmed -split "=", 2

        if ($parts.Count -ne 2) {
            continue
        }

        $name = $parts[0].Trim()
        $value = $parts[1].Trim()

        if ($name -eq "") {
            continue
        }

        if ($value.Length -ge 2) {
            $first = $value.Substring(0, 1)
            $last = $value.Substring($value.Length - 1, 1)

            if (($first -eq '"' -and $last -eq '"') -or ($first -eq "'" -and $last -eq "'")) {
                $value = $value.Substring(1, $value.Length - 2)
            }
        }

        $values[$name] = $value
    }

    return $values
}

function Get-ConfigValue {
    param(
        [hashtable]$Config,
        [string]$Name,
        [string]$DefaultValue = ""
    )

    if ($Config.ContainsKey($Name)) {
        return [string]$Config[$Name]
    }

    return $DefaultValue
}

function Assert-OptionalIPv4 {
    param(
        [string]$Name,
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return
    }

    try {
        $address = [System.Net.IPAddress]::Parse($Value)
    }
    catch {
        throw "$Name must be a valid IPv4 address when set."
    }

    if ($address.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
        throw "$Name must be an IPv4 address when set."
    }
}

function Write-RelayLog {
    param([string]$Message)

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$timestamp] $Message"
    Write-Host $line
    Add-Content -Path $LogPath -Value $line
}

function Convert-IPv4ToUInt32 {
    param([string]$IpAddress)

    $bytes = [System.Net.IPAddress]::Parse($IpAddress).GetAddressBytes()

    return (
        ([uint32]$bytes[0] -shl 24) -bor
        ([uint32]$bytes[1] -shl 16) -bor
        ([uint32]$bytes[2] -shl 8) -bor
        ([uint32]$bytes[3])
    )
}

function Convert-UInt32ToIPv4 {
    param([uint32]$Value)

    $a = ($Value -shr 24) -band 255
    $b = ($Value -shr 16) -band 255
    $c = ($Value -shr 8) -band 255
    $d = $Value -band 255

    return "$a.$b.$c.$d"
}

function Get-IPv4BroadcastAddress {
    param(
        [string]$IpAddress,
        [int]$PrefixLength
    )

    if ($PrefixLength -lt 0 -or $PrefixLength -gt 32) {
        throw "Invalid IPv4 prefix length: $PrefixLength"
    }

    $ipInt = Convert-IPv4ToUInt32 -IpAddress $IpAddress
    $mask = [uint32]0

    for ($i = 0; $i -lt $PrefixLength; $i++) {
        $mask = $mask -bor ([uint32]1 -shl (31 - $i))
    }

    $inverseMask = (-bnot $mask) -band [uint32]::MaxValue
    $broadcastInt = ($ipInt -band $mask) -bor $inverseMask

    return Convert-UInt32ToIPv4 -Value $broadcastInt
}

function Test-IsPrivateLanIPv4 {
    param([string]$IpAddress)

    if ($IpAddress -match "^192\.168\.") {
        return $true
    }

    if ($IpAddress -match "^10\.") {
        return $true
    }

    if ($IpAddress -match "^172\.") {
        $second = [int](($IpAddress -split "\.")[1])
        return ($second -ge 16 -and $second -le 31)
    }

    return $false
}

function Get-LanIPv4Interfaces {
    $configs = Get-NetIPConfiguration |
        Where-Object {
            $_.IPv4Address -and
            $_.NetAdapter -and
            $_.NetAdapter.Status -eq "Up"
        }

    $interfaces = @()

    foreach ($config in $configs) {
        foreach ($addr in $config.IPv4Address) {
            $ip = $addr.IPAddress
            $prefix = $addr.PrefixLength

            if (Test-IsPrivateLanIPv4 -IpAddress $ip) {
                $broadcast = Get-IPv4BroadcastAddress -IpAddress $ip -PrefixLength $prefix

                $interfaces += [pscustomobject]@{
                    Name = $config.InterfaceAlias
                    LocalIp = $ip
                    PrefixLength = $prefix
                    AutoBroadcast = $broadcast
                }
            }
        }
    }

    return $interfaces
}

function New-MagicPacket {
    param([string]$MacAddress)

    $cleanMac = $MacAddress -replace "[:-]", ""

    if ($cleanMac.Length -ne 12) {
        throw "Invalid MAC address length. Set TARGET_MAC to the target device's network adapter MAC."
    }

    if ($cleanMac -notmatch "^[0-9A-Fa-f]{12}$") {
        throw "Invalid MAC address format. Set TARGET_MAC as AA:BB:CC:DD:EE:FF."
    }

    $macBytes = New-Object byte[] 6

    for ($i = 0; $i -lt 6; $i++) {
        $macBytes[$i] = [Convert]::ToByte($cleanMac.Substring($i * 2, 2), 16)
    }

    $packet = New-Object byte[] 102

    for ($i = 0; $i -lt 6; $i++) {
        $packet[$i] = 0xFF
    }

    for ($repeat = 0; $repeat -lt 16; $repeat++) {
        for ($i = 0; $i -lt 6; $i++) {
            $packet[6 + ($repeat * 6) + $i] = $macBytes[$i]
        }
    }

    return $packet
}

function Send-UdpWakePacket {
    param(
        [byte[]]$Packet,
        [string]$LocalIp,
        [string]$DestinationIp,
        [int]$Port
    )

    $localEndpoint = New-Object System.Net.IPEndPoint(
        [System.Net.IPAddress]::Parse($LocalIp),
        0
    )

    $udp = New-Object System.Net.Sockets.UdpClient($localEndpoint)

    try {
        $udp.EnableBroadcast = $true

        [void]$udp.Send(
            $Packet,
            $Packet.Length,
            $DestinationIp,
            $Port
        )

        Write-RelayLog "Sent WOL from $LocalIp to ${DestinationIp}:$Port."
        return "OK    from $LocalIp to ${DestinationIp}:$Port"
    }
    catch {
        $msg = "FAIL  from $LocalIp to ${DestinationIp}:$Port - $($_.Exception.Message)"
        Write-RelayLog $msg
        return $msg
    }
    finally {
        $udp.Close()
        $udp.Dispose()
    }
}

function Send-WakePackets {
    $packet = New-MagicPacket -MacAddress $TargetMac
    $interfaces = @(Get-LanIPv4Interfaces)

    if (-not $interfaces -or $interfaces.Count -eq 0) {
        throw "No active private LAN IPv4 interface found. Check the relay machine's Ethernet or Wi-Fi connection."
    }

    $results = New-Object System.Collections.Generic.List[string]

    foreach ($iface in $interfaces) {
        Write-RelayLog "Using LAN interface '$($iface.Name)' with IP $($iface.LocalIp)/$($iface.PrefixLength), auto broadcast $($iface.AutoBroadcast)."

        $destinations = New-Object System.Collections.Generic.List[string]

        $destinations.Add($iface.AutoBroadcast)

        if (-not [string]::IsNullOrWhiteSpace($ManualBroadcastAddress)) {
            $destinations.Add($ManualBroadcastAddress)
        }

        $destinations.Add("255.255.255.255")

        if (-not [string]::IsNullOrWhiteSpace($TargetIp)) {
            $destinations.Add($TargetIp)
        }

        $uniqueDestinations = $destinations | Select-Object -Unique

        foreach ($destination in $uniqueDestinations) {
            foreach ($port in @(9, 7)) {
                $result = Send-UdpWakePacket `
                    -Packet $packet `
                    -LocalIp $iface.LocalIp `
                    -DestinationIp $destination `
                    -Port $port

                $results.Add($result)
                Start-Sleep -Milliseconds 500
            }
        }
    }

    return $results
}

function Test-RequestAuthorized {
    param([System.Net.HttpListenerRequest]$Request)

    if ([string]::IsNullOrWhiteSpace($WakeKey)) {
        return $true
    }

    $providedKey = $Request.QueryString["key"]

    if ($null -eq $providedKey) {
        return $false
    }

    return [string]::Equals($providedKey, $WakeKey, [System.StringComparison]::Ordinal)
}

function Test-IsLoopbackRequest {
    param([System.Net.HttpListenerRequest]$Request)

    if ($null -eq $Request.RemoteEndPoint -or $null -eq $Request.RemoteEndPoint.Address) {
        return $false
    }

    return [System.Net.IPAddress]::IsLoopback($Request.RemoteEndPoint.Address)
}

function Get-StatusBody {
    $interfaces = @(Get-LanIPv4Interfaces)
    $lines = @()

    foreach ($iface in $interfaces) {
        $lines += "$($iface.Name): $($iface.LocalIp)/$($iface.PrefixLength), broadcast $($iface.AutoBroadcast)"
    }

    if ($lines.Count -eq 0) {
        $lines += "No active private LAN IPv4 interfaces detected."
    }

    $manualBroadcast = "<not set>"
    if (-not [string]::IsNullOrWhiteSpace($ManualBroadcastAddress)) {
        $manualBroadcast = $ManualBroadcastAddress
    }

    $targetIpDisplay = "<not set>"
    if (-not [string]::IsNullOrWhiteSpace($TargetIp)) {
        $targetIpDisplay = $TargetIp
    }

    $wakeKeyState = "not set"
    if (-not [string]::IsNullOrWhiteSpace($WakeKey)) {
        $wakeKeyState = "set"
    }

    return @(
        "Wake relay is running.",
        "",
        "Config:",
        "HTTP port: $HttpPort",
        "Wake key: $wakeKeyState",
        "Manual broadcast: $manualBroadcast",
        "Target IP: $targetIpDisplay",
        "",
        "LAN interfaces:",
        ($lines -join "`r`n")
    ) -join "`r`n"
}

$Config = Read-DotEnv -Path $ConfigPath
$TargetMac = Get-ConfigValue -Config $Config -Name "TARGET_MAC"
$TargetIp = Get-ConfigValue -Config $Config -Name "TARGET_IP"
$ManualBroadcastAddress = Get-ConfigValue -Config $Config -Name "MANUAL_BROADCAST_ADDRESS"
$WakeKey = Get-ConfigValue -Config $Config -Name "WAKE_KEY"
$HttpPortText = Get-ConfigValue -Config $Config -Name "HTTP_PORT" -DefaultValue "8787"

$parsedPort = 0
if (-not [int]::TryParse($HttpPortText, [ref]$parsedPort)) {
    throw "HTTP_PORT must be a number."
}

if ($parsedPort -lt 1 -or $parsedPort -gt 65535) {
    throw "HTTP_PORT must be between 1 and 65535."
}

$HttpPort = $parsedPort

Assert-OptionalIPv4 -Name "TARGET_IP" -Value $TargetIp
Assert-OptionalIPv4 -Name "MANUAL_BROADCAST_ADDRESS" -Value $ManualBroadcastAddress

$ListenPrefix = "http://+:$HttpPort/"

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add($ListenPrefix)

$stopRequested = $false

try {
    $listener.Start()

    Write-RelayLog "Wake relay listening on $ListenPrefix"
    Write-RelayLog "Status URL: http://localhost:$HttpPort/status"
    Write-RelayLog "Wake URL: http://localhost:$HttpPort/wake"
    Write-RelayLog "Stop URL: http://localhost:$HttpPort/stop"

    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        Write-RelayLog "No .env file found. Copy .env.example to .env and set TARGET_MAC before using /wake."
    }

    if ([string]::IsNullOrWhiteSpace($WakeKey)) {
        Write-RelayLog "WAKE_KEY is blank. /wake is not key protected."
    }
    else {
        Write-RelayLog "WAKE_KEY is set. /wake requires the key query parameter."
    }

    while ($listener.IsListening -and -not $stopRequested) {
        $context = $listener.GetContext()
        $request = $context.Request
        $response = $context.Response

        $path = $request.Url.AbsolutePath.TrimEnd("/")
        if ($path -eq "") {
            $path = "/"
        }

        try {
            if ($path -eq "/wake") {
                if (-not (Test-RequestAuthorized -Request $request)) {
                    $response.StatusCode = 401
                    $body = "Unauthorized."
                    Write-RelayLog "Rejected unauthorized /wake request."
                }
                else {
                    $results = Send-WakePackets
                    $response.StatusCode = 200
                    $body = "Wake sequence sent.`r`n`r`n" + ($results -join "`r`n")
                }
            }
            elseif ($path -eq "/status") {
                $response.StatusCode = 200
                $body = Get-StatusBody
            }
            elseif ($path -eq "/stop") {
                if (-not (Test-IsLoopbackRequest -Request $request)) {
                    $response.StatusCode = 403
                    $body = "The stop endpoint is available only from the relay computer."
                    Write-RelayLog "Rejected non-local /stop request."
                }
                elseif (-not (Test-RequestAuthorized -Request $request)) {
                    $response.StatusCode = 401
                    $body = "Unauthorized."
                    Write-RelayLog "Rejected unauthorized /stop request."
                }
                else {
                    $response.StatusCode = 200
                    $body = "Wake relay stopping."
                    $stopRequested = $true
                }
            }
            else {
                $response.StatusCode = 404
                $body = "Use /wake, /status, or /stop"
            }
        }
        catch {
            $response.StatusCode = 500
            $body = "Error: $($_.Exception.Message)"
            Write-RelayLog "ERROR: $($_.Exception.Message)"
        }

        $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
        $response.ContentType = "text/plain"
        $response.ContentLength64 = $bytes.Length
        $response.OutputStream.Write($bytes, 0, $bytes.Length)
        $response.OutputStream.Close()
    }
}
finally {
    if ($listener.IsListening) {
        $listener.Stop()
    }

    $listener.Close()
    Write-RelayLog "Wake relay stopped."
}
