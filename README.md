# Block Pornographic sites, images and content completely from your device

## Device-wide domain blocking (`filterd`)

Privileged local DNS filter that loads lists from `dns-blocklists/` and blocks matching hostnames.

```powershell
cd filterd
go test ./...
go build -o filterd.exe ./cmd/filterd

# Policy check (no network changes)
.\filterd.exe test example.com

# Dev DNS proxy on 127.0.0.1:8053 (loads filterd/nsfw.txt by default)
.\filterd.exe run

# Windows system-wide (Administrator) — still uses filterd/nsfw.txt
.\filterd.exe run -listen 127.0.0.1:53 -system-dns -lockdown

# If DNS was left pointing at localhost after a crash:
.\filterd.exe restore-dns
```

See [`filterd/README.md`](filterd/README.md) for architecture, limits (DoH/VPN), and fail-open recovery.

## Browser extension (domains + search text + images)

System DNS (`filterd`) **cannot** see traffic inside a browser VPN extension
(proxy tunnel + remote DNS). The companion extension also runs ML on search
queries (from the URL) and page images via a **local** API:

```powershell
# 1) Local ML API (text + image models) — leave this running
cd classifier-api
conda activate py3.10
pip install -r requirements.txt   # first time
.\run.ps1

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

## Content classifiers (models)

- `text-classifier/` — NSFW text labels (`safe` / `nsfw`)  
- `image-classifier/` — multi-class image labels (`Normal`, `Pornography`, …)  
- `classifier-api/` — FastAPI wrapper the extension calls on `127.0.0.1:8765`  

These are for browser/extension content flows, not the DNS path.


