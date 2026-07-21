# filterd

Local DNS domain blocker for Windows. Loads HaGeZi-style lists, answers DNS on localhost, points the OS at itself, and **runs as a Windows service** so protection survives reboot without opening a terminal.

## Ship it (no terminal for the end user)

```powershell
cd filterd
.\scripts\pack-ship.ps1
# → dist\NoPornForever-filterd-windows-amd64.zip
```

On the target PC:

1. Unzip  
2. Right-click **`INSTALL.bat`** → **Run as administrator** (once)  
3. Done — auto-starts at boot  

Uninstall: **`UNINSTALL.bat`** as administrator.

See [SHIP.md](SHIP.md).

## What install does

| Step | Detail |
|------|--------|
| Copy | `filterd.exe` + `nsfw.txt` → `%ProgramFiles%\NoPornForever\filterd\` |
| Service | `NoPornForeverFilterd` — **Automatic (delayed)** start |
| Recovery | Restart on failure (5s / 30s / 60s) |
| Protect | System DNS → `127.0.0.1`, listen `:53`, lockdown + Chrome/Edge DoH off |
| Log | `%ProgramData%\NoPornForever\filterd\filterd.log` |

After install, **no daily command** is required.

## Commands (optional / power users)

```text
filterd install       # same as INSTALL.bat (Admin)
filterd uninstall     # stop, restore DNS, remove service
filterd start|stop
filterd status
filterd restore-dns   # emergency fail-open
filterd test domain   # list check only
filterd run -protect  # foreground (dev); Ctrl+C restores DNS
```

## Build from source

```powershell
cd filterd
go test ./...
go build -o filterd.exe ./cmd/filterd
```

## Why `test` blocks but Chrome still works

| Command | Effect on browser |
|--------|-------------------|
| `filterd test x` | **None** — only checks the list file |
| `filterd run` | **None** — listens on `:8053`, OS DNS unchanged |
| `filterd install` or `run -protect` | **Yes** — OS DNS → `127.0.0.1:53` |

## Safety

- **Fail-open on graceful stop:** service stop / uninstall restores previous DNS  
- **Hard kill:** recovery restarts the service; if DNS is stuck, run `restore-dns` or UNINSTALL  
- Large lists load once into memory; matching walks parent labels  

## Not in scope

- Raw IP access, custom DoH, VPN tunnel DNS  
- Image/text ML (browser extension + classifier-api)  
- macOS/Linux service adapters (stubs only)
