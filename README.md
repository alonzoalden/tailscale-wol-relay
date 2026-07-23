# tailscale-wol-relay

*A tiny Windows/Tailscale relay for waking a sleeping PC from outside your home network.*

`tailscale-wol-relay` is a small, dependency-free PowerShell Wake-on-LAN relay for Windows.

It lets a remote device wake a sleeping PC by calling an HTTP endpoint on an always-on Windows machine that is already inside the same LAN:
```text
Remote device -> Tailscale -> always-on Windows relay -> LAN Wake-on-LAN broadcast -> sleeping PC
```

## Why a Relay Is Needed

Wake-on-LAN magic packets are usually delivered by local Ethernet broadcast or local subnet traffic. Tailscale gives you secure connectivity to a machine, but it does not turn remote HTTP traffic into LAN broadcast packets for a sleeping device. This relay bridges that gap: Tailscale reaches the always-on Windows machine, then the relay sends WOL packets on the local LAN.

The relay does not assume a `/24` subnet. It detects active private LAN IPv4 interfaces and calculates the correct broadcast address from the local IP and prefix length. For example, a relay at `10.10.4.250/22` correctly broadcasts to `10.10.7.255`, not `10.10.4.255`.

## Files

```text
tailscale-wol-relay/
  wake-server.ps1
  .env.example
  .gitignore
  README.md
  LICENSE
  scripts/
    install-startup-task.ps1
    uninstall-startup-task.ps1
```

## Prerequisites

Before setup:

- The Windows relay machine should be powered on and connected to the same LAN as the target device you want to wake.
- Tailscale for Windows must be installed, signed in, and connected once before installing the relay startup task.
- The target device should be awake at least once during setup so you can find its network adapter MAC address.
- After setup, the relay machine should stay awake whenever you want remote wake access.
- The target device must have Wake-on-LAN enabled in its firmware, operating system, and network adapter settings where applicable.

> Tested target: Windows desktop PC with wired Ethernet. The relay sends standard Wake-on-LAN packets and may work with other Wake-on-LAN-capable devices, but wake behavior depends on the target hardware, network adapter, operating system, and sleep/power state.

## Setup

Run these commands from the repo root on the always-on Windows relay machine.

```powershell
Copy-Item .env.example .env
notepad .env
```

Edit `.env`:

```env
TARGET_MAC=AA:BB:CC:DD:EE:FF
TARGET_IP=
MANUAL_BROADCAST_ADDRESS=
HTTP_PORT=8787
WAKE_KEY=change-me
```

Config values:

- `TARGET_MAC`: Required for `/wake`. Use the target device's network adapter MAC address.
- `TARGET_IP`: Optional last-known LAN IP of the target device. Do not use the Tailscale IP.
- `MANUAL_BROADCAST_ADDRESS`: Optional fallback broadcast address. Leave blank unless you need to force one.
- `HTTP_PORT`: HTTP listener port. Defaults to `8787`.
- `WAKE_KEY`: Optional shared key for `/wake`. If blank, `/wake` is unauthenticated.

## Run the Server

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\wake-server.ps1
```

The server exposes:

- `GET /status`
- `GET /wake?key=change-me`
- `GET /stop?key=change-me` (relay computer only)

The script listens on `http://+:8787/` by default so it can accept requests through the relay machine's Tailscale IP. The startup installer runs the deployed copy under the built-in `SYSTEM` service account, which can register this listener without a URL reservation. If you want to run the script manually as a standard user and Windows denies the HTTP listener prefix, run PowerShell as Administrator once and add a URL reservation:

```powershell
netsh http add urlacl url=http://+:8787/ user="$env:USERDOMAIN\$env:USERNAME"
```

## Test Locally

```powershell
Invoke-WebRequest -UseBasicParsing http://localhost:8787/status
Invoke-WebRequest -UseBasicParsing "http://localhost:8787/wake?key=change-me"
```

If `WAKE_KEY` is blank in `.env`, call `/wake` without the `key` query parameter.

## Test Over Tailscale

Find the relay machine's Tailscale IP:

```powershell
tailscale ip -4
```

From another Tailscale device, replace `100.x.y.z` with the relay machine's Tailscale IP:

```powershell
Invoke-WebRequest -UseBasicParsing http://100.x.y.z:8787/status
Invoke-WebRequest -UseBasicParsing "http://100.x.y.z:8787/wake?key=change-me"
```

## Windows Firewall

The startup installer creates and maintains a firewall rule that allows only Tailscale source addresses (`100.64.0.0/10`) to reach the configured TCP port.

If you run the server without installing the startup task, create the rule manually from PowerShell running as Administrator:

```powershell
New-NetFirewallRule -DisplayName "Tailscale WOL Relay 8787" -Direction Inbound -Action Allow -Protocol TCP -LocalPort 8787 -RemoteAddress 100.64.0.0/10 -Profile Any
```

If you change `HTTP_PORT`, update `-LocalPort` to match.

## Install at Startup

Open PowerShell **as Administrator**, change to the repository directory, and run:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\scripts\install-startup-task.ps1
```

The installer requires a configured `.env` beside `wake-server.ps1`. It then:

- copies `wake-server.ps1` and `.env` into the protected `%ProgramData%\TailscaleWolRelay` directory;
- sets the Windows `Tailscale` service to Automatic, enables [Tailscale's unattended mode](https://tailscale.com/docs/how-to/run-unattended), and verifies that it has a `100.x` address;
- creates a task named `TailscaleWolRelay` that runs as `SYSTEM` at system startup, without waiting for user logon;
- adds a logon trigger as a fallback and ignores duplicate instances;
- removes Task Scheduler's default execution time limit;
- restarts the process after failures;
- allows the task to start and continue while the relay laptop is on battery;
- creates the Tailscale-scoped Windows Firewall rule;
- starts the task immediately and checks `http://localhost:8787/status`.

Running a `SYSTEM` task directly from a user-writable checkout would create a local privilege-escalation path. The protected deployed copy avoids that problem. Re-run the installer after changing `wake-server.ps1`, `.env`, or `HTTP_PORT`; it safely replaces the deployed copy, task definition, and firewall rule.

The relay computer itself must remain awake. Task Scheduler can restart the process, but it cannot serve requests while Windows is sleeping or hibernating. Configure the relay laptop's plugged-in sleep settings accordingly.

Uninstall the task:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\scripts\uninstall-startup-task.ps1
```

By default, uninstalling preserves the deployed `.env` and logs. Delete those as well with:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\scripts\uninstall-startup-task.ps1 -RemoveData
```

## Check the Installed Relay

Run these commands from PowerShell on the relay computer:

```powershell
Get-ScheduledTask -TaskName TailscaleWolRelay |
    Select-Object TaskName, State

Get-ScheduledTaskInfo -TaskName TailscaleWolRelay |
    Select-Object LastRunTime, LastTaskResult

Get-Service -Name Tailscale |
    Select-Object Name, Status, StartType

tailscale status
tailscale ip -4
Get-NetTCPConnection -State Listen -LocalPort 8787
Invoke-WebRequest -UseBasicParsing http://localhost:8787/status
Get-Content "$env:ProgramData\TailscaleWolRelay\wake-server.log" -Tail 30
```

The expected task and Tailscale service states are both `Running`, `tailscale ip -4` should return the relay's `100.x` address, the TCP listener should be present, and `/status` should return `Wake relay is running.`

## Troubleshooting

- Confirm `TARGET_MAC` is the target device's network adapter MAC address, not Wi-Fi, Bluetooth, or a virtual adapter.
- Do not use the Tailscale IP for `TARGET_IP`; it must be the target device's LAN IP if you set it.
- Do not assume `x.x.x.255` is the correct broadcast address. `/status` shows the calculated broadcast for each detected LAN interface.
- If `/status` works over Tailscale but `/wake` fails, the relay HTTP path is working and the remaining issue is local WOL delivery.
- If a manual, non-administrator run cannot bind to `http://+:8787/`, run the one-time URL ACL setup from the run instructions. The installed startup task runs under `SYSTEM` and does not need that reservation.
- If Tailscale connects only after opening its tray application, re-run the startup installer as Administrator. It enables Windows unattended mode so Tailscale connects before user logon.
- If the relay works at `localhost` but not through its Tailscale IP, reinstall the startup task to refresh its firewall rule and confirm the peer is allowed by your Tailscale access policy.
- Remote requests to `/stop` are rejected. From the relay computer, `/stop` requires the wake key when `WAKE_KEY` is set. For normal administration, prefer `Stop-ScheduledTask -TaskName TailscaleWolRelay`.
- Make sure the relay machine does not sleep.
- Make sure the target device has Wake-on-LAN enabled in its firmware, operating system, and network adapter settings where applicable.
- Some networks block directed broadcast or WOL across Wi-Fi. A wired relay and wired target are the most reliable setup.
- Check `%ProgramData%\TailscaleWolRelay\wake-server.log` for installed-task startup, send attempts, and interface detection details. The wake key is never logged.

## License

MIT
