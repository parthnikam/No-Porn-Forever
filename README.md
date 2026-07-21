# Block Pornographic sites, images and content completely from your device

## Device-wide domain blocking (`filterd`)

Privileged local DNS filter that loads lists from `dns-blocklists/` and blocks matching hostnames.

```powershell
cd filterd
go test ./...
go build -o filterd.exe ./cmd/filterd

# Policy check (no network changes)
.\filterd.exe test example.com

# Dev DNS proxy on 127.0.0.1:8053
.\filterd.exe run -lists ..\dns-blocklists\nsfw.txt,..\dns-blocklists\tif.mini.txt

# Windows system-wide (Administrator)
.\filterd.exe run -listen 127.0.0.1:53 -system-dns -lockdown -lists ..\dns-blocklists\nsfw.txt,..\dns-blocklists\tif.mini.txt

# If DNS was left pointing at localhost after a crash:
.\filterd.exe restore-dns
```

See [`filterd/README.md`](filterd/README.md) for architecture, limits (DoH/VPN), and fail-open recovery.

## Content classifiers (separate from DNS)

- `text-classifier/` — NSFW text labels  
- `image-classifier/` — NSFW image labels / multi-class categorizer  

These are for browser/extension flows, not the DNS path.


