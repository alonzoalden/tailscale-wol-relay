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
- `GET /stop`

The script listens on `http://+:8787/` by default so it can accept requests through the relay machine's Tailscale IP. If Windows denies the HTTP listener prefix, run PowerShell as Administrator and add a URL reservation:

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

Allow Tailscale clients to reach the relay port. Run PowerShell as Administrator:

```powershell
New-NetFirewallRule -DisplayName "Tailscale WOL Relay 8787" -Direction Inbound -Action Allow -Protocol TCP -LocalPort 8787 -RemoteAddress 100.64.0.0/10 -Profile Any
```

If you change `HTTP_PORT`, update `-LocalPort` to match.

## Install at Startup

Install a current-user scheduled task that starts the relay when you log on:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\scripts\install-startup-task.ps1
```

The installer creates a task named `TailscaleWolRelay` using:

```text
powershell.exe -ExecutionPolicy Bypass -File <path-to-wake-server.ps1>
```

Admin permissions are usually not required for this current-user logon task. You may need admin permissions if you are replacing a task created by another user, changing machine-wide policy, adding the HTTP URL reservation, or opening the Windows firewall.

The task uses the ScheduledTasks `Limited` run level for the normal current-user install path. The relay may still need the one-time URL ACL setup if Windows does not allow the user account to bind `http://+:8787/`.

Uninstall the task:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\scripts\uninstall-startup-task.ps1
```

## Troubleshooting

- Confirm `TARGET_MAC` is the target device's network adapter MAC address, not Wi-Fi, Bluetooth, or a virtual adapter.
- Do not use the Tailscale IP for `TARGET_IP`; it must be the target device's LAN IP if you set it.
- Do not assume `x.x.x.255` is the correct broadcast address. `/status` shows the calculated broadcast for each detected LAN interface.
- If `/status` works over Tailscale but `/wake` fails, the relay HTTP path is working and the remaining issue is local WOL delivery.
- If the relay cannot bind to `http://+:8787/`, run the one-time URL ACL setup from the run instructions. The scheduled task itself should still use `Limited` unless elevated startup is explicitly needed.
- Make sure the relay machine does not sleep.
- Make sure the target device has Wake-on-LAN enabled in its firmware, operating system, and network adapter settings where applicable.
- Some networks block directed broadcast or WOL across Wi-Fi. A wired relay and wired target are the most reliable setup.
- Check `wake-server.log` for send attempts and interface detection details. The wake key is never logged.

## License

MIT
