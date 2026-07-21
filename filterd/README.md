# filterd

Local DNS domain blocker. Loads HaGeZi-style lists from `dns-blocklists/`, answers DNS on localhost, and (on Windows) can point system DNS at itself.

## What it does

1. Loads blocklists (`||domain^` / hosts-style).
2. Matches exact names and **parent domains** (`a.b.example.com` hits `example.com`).
3. Runs a DNS proxy: **blocked → NXDOMAIN**, else forward to upstream.
4. **Windows:** optional system DNS takeover + light anti-bypass firewall rules.
5. On stop: restores previous DNS (**fail-open**).

## What it does **not** do

- Stop raw-IP access, custom DoH, or VPN-internal DNS  
- Work the same on every OS without a native adapter  
- MITM HTTPS or install a root CA  
- Use the ML image/text classifiers (those belong in the browser extension)

## Build

```powershell
cd filterd
go test ./...
go build -o filterd.exe ./cmd/filterd
```

## Quick test (no admin, no system DNS change)

```powershell
# Policy check only
.\filterd.exe test something.blocked.test -lists testdata\sample-block.txt

# Dev proxy on port 8053 (no admin)
.\filterd.exe run -lists ..\dns-blocklists\nsfw.txt,..\dns-blocklists\tif.mini.txt -allow allowlist.txt

# In another terminal (helper ships with the module):
go build -o dnsping.exe ./cmd/dnsping
.\dnsping.exe 127.0.0.1:8053 example.com. some-blocked-host.
```

## Windows system-wide (Administrator)

```powershell
# Take over adapter DNS + listen on :53 + block common public DNS bypass IPs
.\filterd.exe run -listen 127.0.0.1:53 -system-dns -lockdown -lists ..\dns-blocklists\nsfw.txt,..\dns-blocklists\tif.mini.txt -allow allowlist.txt

# Emergency recovery if the process died without restoring DNS:
.\filterd.exe restore-dns
.\filterd.exe status
```

Upstream default is `1.1.1.1:53`. Lockdown **exempts** that upstream IP from the public-resolver block list so filterd can still recurse.

## Commands

| Command | Purpose |
|--------|---------|
| `run` | Start proxy |
| `test <domain>` | Print BLOCK/ALLOW |
| `status` | Snapshot + current adapter DNS |
| `restore-dns` | Fail-open recovery |

## Layout

```text
filterd/
  core/                 # parse, match, DNS proxy (portable)
  platform/windows/     # DNS set/restore, firewall lockdown
  platform/macos/       # stub
  platform/linux/       # stub
  cmd/filterd/          # CLI
  allowlist.txt
  testdata/
```

## Safety notes

- Prefer **fail-open**: Ctrl+C restores DNS when `-system-dns` was used.
- If the process is killed hard, run `filterd restore-dns`.
- Large lists take a few seconds to load into memory once; matching is O(labels).
- Browser **Secure DNS / DoH** can bypass this — disable it or use a companion extension.
