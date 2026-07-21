<img src="assets/logo_banner.png" alt="Local Image" width="1000" />

# Block Pornographic sites, images and content completely from your device

## Device-wide domain blocking (`filterd`)

Privileged local DNS filter. **Install once as a Windows service** — auto-starts at boot, no terminal every day.

```powershell
cd filterd
.\scripts\pack-ship.ps1
# Ship: dist\EasyPeasy-filterd-windows-amd64.zip
# User: unzip → right-click INSTALL.bat → Run as administrator
```

Or from a built tree (Administrator):

```powershell
.\filterd.exe install      # service + protect + auto-start
.\filterd.exe status
.\filterd.exe uninstall    # stop + restore DNS
```

See [`filterd/README.md`](filterd/README.md) and [`filterd/SHIP.md`](filterd/SHIP.md).

## Browser extension (domains + search text + images)

System DNS (`filterd`) **cannot** see traffic inside a browser VPN extension
(proxy tunnel + remote DNS). The companion extension also runs ML on search
queries (from the URL) and page images via a **local** API:

```powershell
# 1) Local ML API — install once (auto-starts at every logon)
cd classifier-api
conda activate py3.10
pip install -r requirements.txt   # first time
.\INSTALL.bat                     # or: .\install.ps1

# 2) Load the extension
cd ..\extension
.\scripts\sync-list.ps1
# Chrome → chrome://extensions → Developer mode → Load unpacked → select extension/
```

| Layer | Role |
|-------|------|
| Domain list | Blocks hosts in `nsfw.txt` (works under VPN extensions) |
| Search / URL text | Extracts `?q=` etc. → text classifier → block NSFW searches |
| Images | Classifies `<img>` → removes anything not **Normal** |

See [`extension/README.md`](extension/README.md) and [`classifier-api/`](classifier-api/).  
Use **filterd + Content Guard extension + classifier-api** together.

**Lock Incognito/Guest (Admin):** `extension/scripts/lock-browsers.ps1` — details in [`docs/BROWSER_LOCKDOWN.md`](docs/BROWSER_LOCKDOWN.md).

## Content classifiers (models)

- `text-classifier/` — NSFW text labels (`safe` / `nsfw`)  
- `image-classifier/` — multi-class image labels (`Normal`, `Pornography`, …)  
- `classifier-api/` — FastAPI wrapper the extension calls on `127.0.0.1:8765`  

These are for browser/extension content flows, not the DNS path.


