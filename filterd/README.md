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
```

## Default list: `filterd/nsfw.txt`

With no `-lists` flag, filterd loads the HaGeZi NSFW list sitting next to the binary:

```text
filterd/nsfw.txt
```

Optional threat list from the repo can be added explicitly:

```powershell
.\filterd.exe run -lists nsfw.txt,..\dns-blocklists\tif.mini.txt
```

## Why `test` blocks but Chrome still works

| Command | What it does |
|--------|----------------|
| `filterd test domain` | Checks the **list only**. No effect on browsers. |
| `filterd run` | Listens on **127.0.0.1:8053**. OS DNS is unchanged → browsers ignore it. |
| `filterd run -protect` | **Admin required.** Sets OS DNS to `127.0.0.1`, listens on port **53**. |

Right now if your adapters still show the router (e.g. `192.168.0.1`), the browser never talks to filterd.

Also disable browser **Secure DNS / DNS over HTTPS** (Chrome: Settings → Privacy → Use secure DNS → **Off** / use your current service provider), or Chrome will skip the OS resolver.

## Quick test (no admin — does not filter the browser)

```powershell
.\filterd.exe test xhamster.com
.\filterd.exe run
# only queries aimed at 127.0.0.1:8053 are filtered
```

## Filter the browser (Administrator)

```powershell
# 1) Stop any old filterd first
Get-Process filterd -ErrorAction SilentlyContinue | Stop-Process -Force

# 2) Start protection (Admin terminal)
cd filterd
.\filterd.exe run -protect

# 3) Confirm EVERY adapter is only 127.0.0.1 (not the router on Ethernet/Wi-Fi)
Get-DnsClientServerAddress -AddressFamily IPv4 | Format-Table InterfaceAlias,ServerAddresses

# 4) Fully quit Chrome/Edge (all windows) and reopen — DoH policy applies on restart
# 5) Hard-refresh or try an Incognito window (avoids cached IPs)

# Emergency recovery:
.\filterd.exe restore-dns
```

### Common bypass we fixed

| Leak | What happens |
|------|----------------|
| Ethernet still on router DNS while Wi-Fi is 127.0.0.1 | Windows queries **both**; router answers and site loads |
| Chrome/Edge Secure DNS (DoH) | Browser resolves over HTTPS; ignores OS DNS |
| DNS cache | Old IP still used until flush / new browser session |

`-protect` now: rewrites **all** adapters, disables smart multi-homed DNS, turns off Chrome/Edge DoH policy, blocks common DoH IPs on :443, flushes cache.

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
