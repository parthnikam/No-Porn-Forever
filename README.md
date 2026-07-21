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

## Browser VPN extensions

System DNS (`filterd`) **cannot** see traffic inside a browser VPN extension
(proxy tunnel + remote DNS). Install the companion extension:

```powershell
cd extension
.\scripts\sync-list.ps1
# Chrome → chrome://extensions → Developer mode → Load unpacked → select extension/
```

See [`extension/README.md`](extension/README.md). Use **filterd + Domain Guard** together.

## Content classifiers (separate from DNS)

- `text-classifier/` — NSFW text labels  
- `image-classifier/` — NSFW image labels / multi-class categorizer  

These are for browser/extension content flows, not the DNS path.


