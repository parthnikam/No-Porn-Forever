# Ship filterd (hackathon / standalone)

## What the user does

1. Unzip `EasyPeasy-filterd-windows-amd64.zip`
2. Right-click **`INSTALL.bat`** → **Run as administrator**
3. Click through UAC once  
4. Close the window — **done**

Protection:

- Starts **immediately**
- Starts **automatically at every boot** (Windows service)
- Restarts if the process crashes (SCM recovery)
- No terminal, no `go`, no daily ritual

## What gets installed

| Item | Location |
|------|----------|
| Binary + `nsfw.txt` | `%ProgramFiles%\EasyPeasy\filterd\` |
| Windows service | `EasyPeasyFilterd` (Automatic, delayed start) |
| Log file | `%ProgramData%\EasyPeasy\filterd\filterd.log` |
| DNS snapshot | `%AppData%\filterd\dns_snapshot.json` (via UserConfigDir for SYSTEM may differ; uses default snapshot path API) |

> Note: the service runs as **LocalSystem**. Snapshot path uses the system profile’s config dir when running as the service.

## Uninstall

Right-click **`UNINSTALL.bat`** → Run as administrator  

Or:

```text
filterd uninstall
```

Stops service, restores DNS, removes the service registration.

## Emergency: “no internet” after a kill

If the process was hard-killed before DNS restore:

1. Run **UNINSTALL.bat** as Admin, or  
2. `filterd restore-dns` as Admin, or  
3. Adapter settings → DNS → “Obtain automatically”

## Build the zip (developer)

```powershell
cd filterd
.\scripts\pack-ship.ps1
```

## Limits (still true)

- Task Manager can stop the **service** if the user is admin (recovery may restart the process after End task on the exe; a deliberate `Stop-Service` sticks until start)
- Does not replace the browser extension for VPN/DoH edge cases
- Does not run ML image/text classifiers (that’s the extension + local API)
