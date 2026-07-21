# DNS Domain Blocker — Implementation Plan

## Verdict on SPEC1.md

SPEC1 is **directionally correct** and **not something you should throw away**. The core insight is right:

> A real device-wide blocker is a **privileged local DNS filter + OS enforcement**, not a hosts-file tweak and not an NPX package.

Where SPEC1 fails you is **product theater**: it mixes a solid architecture with a multi-month production roadmap (WFP callouts, signed update CDN, VPN product modes, Tauri UI, macOS system extensions, captive portals, accountability locks) and presents that as if it is one coherent build. That is why it feels circular — lots of layers, few shippable milestones.

### What SPEC1 got right (keep)

| Claim | Why it is correct |
| --- | --- |
| Privileged background service, not a script users re-run | Only a service can own system DNS continuously |
| Shared filter core + **native OS adapters** | “Cross-platform” cannot mean one networking API |
| Domain matching must walk parent labels | `a.b.example.com` should hit `example.com` |
| DNS alone is bypassable | Direct `8.8.8.8:53`, DoH, hard-coded resolvers |
| Do not MITM HTTPS with a local root CA | Huge security/complexity cost; wrong for this product |
| Do not promise “works with every VPN / unkillable” | Honest marketing; VPNs can own DNS inside the tunnel |
| MVP data structure = in-memory hash set | ~100k–300k domains is trivial in RAM |
| Fail-open vs fail-closed is a product choice | Crashing must not silently brick networking without intent |

### What SPEC1 over-engineers (cut for v1)

| SPEC1 idea | Why defer |
| --- | --- |
| Backend “compile and sign blocklist releases” | Ship local files from `dns-blocklists/` first |
| Full WFP callout drivers | User-mode DNS + simple firewall rules are enough for a demo |
| Perfect multi-OS installers day one | Empty `desktop/*` folders; pick **one** OS to finish |
| Tauri dashboard, accountability, watchdogs | CLI/tray + logs first |
| Strict VPN modes as a product surface | Detect/warn later; do not block all tunnels in v1 |
| Local block-page HTTP server | `NXDOMAIN` is enough; HTTPS block pages need cert hacks |
| Claiming “all operating systems” equally | Same **logic**, different **enforcement** — months apart |

### Skeptical one-liner

**SPEC1 describes the right end-state architecture for a commercial filter product. It is not an implementation plan for a hackathon or first working build.** Your plan should shrink to: *load lists → answer DNS → point OS DNS at us → block obvious bypass → restore on exit.*

---

## Problem definition (actual)

**Goal:** Intercept hostname resolution on the machine and refuse names that appear in local blocklists (`dns-blocklists/nsfw.txt`, `dns-blocklists/tif.mini.txt`), so browsers and most apps cannot open those sites by name.

**Non-goals (v1):**

- Stopping someone who already has the raw IP
- Stopping every DoH client on the internet
- Surviving a determined admin with Task Manager + DNS reset
- Perfect VPN compatibility
- Image/text NSFW classifiers at the network layer (those belong in the **browser extension**, not DNS)

**Blocklist format you already have:** HaGeZi / Adblock Plus DNS lists (`||domain.example^`). Parse offline into a normalized domain set; do not interpret full ABP cosmetic rules.

---

## Honest cross-platform model

```text
┌──────────────────────────────────────────┐
│ SHARED CORE (portable)                   │
│  parse lists · match domains · DNS I/O   │
│  forward allowed queries upstream        │
└──────────────────┬───────────────────────┘
                   │
     ┌─────────────┼─────────────┐
     ▼             ▼             ▼
 Windows       macOS          Linux
 set NIC DNS   Network        resolv /
 firewall      Extension*     nftables*
 service       + signing*     + systemd*
```

\*macOS Network Extension and production Linux packaging are **real** work (signing, user approval, distro fragmentation). They are not “compile the same binary.”

| Capability | Shared code? | Windows | macOS (real) | Linux (Ubuntu) |
| --- | --- | --- | --- | --- |
| Domain match + DNS proxy | Yes | Yes | Yes | Yes |
| Force system DNS through proxy | No | `netsh` / IP Helper | DNS Proxy provider | NetworkManager / resolved |
| Block direct DNS to 8.8.8.8 | No | Firewall / WFP | Content filter / rules | nftables by UID |
| Install as always-on service | No | Windows Service | LaunchDaemon + NE | systemd |
| Demo in a weekend | — | **Yes** | Stretch / prototype DNS-only | Stretch if you know Linux |

**Recommendation:** Implement **Windows completely**. Keep shared core clean so macOS/Linux adapters are thin later. Do not claim “all OS” until each adapter exists.

You are already on Windows with a CUDA env; that matches building Windows first.

---

## Architecture for the first shippable version

```text
App / Browser
    → OS DNS (pointed at 127.0.0.1)
        → filterd DNS proxy :53
            → normalize name
            → allowlist? → upstream DNS (1.1.1.1 / 8.8.8.8 / configured)
            → blocklist match (name + parents)? → NXDOMAIN
            else → forward upstream, return answer

Optional (same process or helper):
    outbound firewall: only filterd may use UDP/TCP 53 (and maybe 853)
```

### Components

1. **Blocklist loader**  
   - Read `||host^` lines, strip comments/`[Adblock Plus]` headers  
   - Lowercase, strip trailing dots, validate labels  
   - Build `HashSet` of blocked domains (and optionally a suffix index)

2. **Matcher**  
   For query `images.foo.example.com`, check in order:  
   `images.foo.example.com` → `foo.example.com` → `example.com` → `com` (usually skip public suffix-only if you want; simplest is check all parents)

3. **DNS proxy**  
   - Listen `127.0.0.1:53` (and later `::1` if you enable IPv6)  
   - Handle A/AAAA (and optionally HTTPS/SVCB) queries at minimum  
   - Upstream: plain DNS UDP to a configured resolver  
   - Block response: **NXDOMAIN** (simplest; good enough)

4. **OS adapter (Windows v1)**  
   - Require admin  
   - Snapshot current DNS per active interface  
   - Set DNS to `127.0.0.1`  
   - On clean shutdown / uninstall: restore snapshot  
   - Re-apply when a new adapter appears (Wi-Fi switch) — phase 1.5

5. **Bypass reduction (Windows v1.5)**  
   - Windows Firewall (or simple WFP user-mode filters):  
     allow *this* process → UDP/TCP 53 outbound; block others → 53  
   - Optionally block TCP 853 (DoT) for others  
   - Blocklist known public DoH hostnames *in* the domain list (so even if DoH is used via name, first resolution fails — incomplete but cheap)

6. **Control surface**  
   - CLI: `start | stop | status | test <domain> | reload-lists`  
   - Logs: blocked count, last N blocked domains  
   - UI later

### Fail-safe (pick one and document it)

| Mode | Behavior if filterd dies | Use when |
| --- | --- | --- |
| **Fail-open** (default v1) | Restore system DNS *or* leave DNS at 127.0.0.1 only if a watchdog restores settings | Normal use — do not brick hotel Wi-Fi |
| Fail-closed | Leave DNS on 127.0.0.1 with nothing listening | “Commitment” mode only, later |

For v1: **on service stop/crash, restore previous DNS**. That is fail-open for connectivity.

---

## Language choice (pragmatic)

SPEC1 pushes **Rust**. That is fine long-term. It is not mandatory.

| Stack | Fit |
| --- | --- |
| **Go** | Best pragmatic default: single binary, mature DNS libs (`miekg/dns`), easy Windows service, fast enough |
| **Rust** | Excellent if the team already writes Rust; more setup cost |
| **Python** | Good for **list tooling** and your classifiers; poor as the privileged always-on DNS service (packaging, GIL, service story) |

**Plan assumption:** Go (or Rust if you insist) for `filterd`; keep Python classifiers and the browser extension separate. Do not put the DNS path through HuggingFace models.

---

## Repo shape (small)

```text
dns-blocklists/          # existing raw lists (source of truth for v1)
filterd/
  core/
    lists.go             # parse HaGeZi lines
    match.go             # parent-domain match
    dnsproxy.go          # serve + forward
  platform/
    windows/
      dns_config.go      # get/set/restore adapter DNS
      firewall.go        # optional port-53 lock
      service.go         # Windows service wrapper
    macos/               # stub README only until started
    linux/               # stub README only until started
  cmd/filterd/main.go
  testdata/              # tiny list fixtures
```

Empty `desktop/windows|macos|linux` can become installers later; **logic lives in `filterd/`**, not three copy-pasted projects.

---

## Implementation phases (ship order)

### Phase 0 — Core works offline (1–2 days)

**Done when:** without changing system DNS, you can run the proxy on `127.0.0.1:5353` and prove matching.

- [ ] Parse `nsfw.txt` / `tif.mini.txt` into a set (skip comments)
- [ ] Unit tests: exact match, subdomain match, allowlist override, invalid lines ignored
- [ ] DNS proxy on non-privileged port `5353` for dev
- [ ] `filterd test pornhub.com` → BLOCK; `filterd test example.com` → ALLOW (assuming not on list)
- [ ] Manual: `nslookup example.com 127.0.0.1 -port=5353`

No installer. No firewall. No UI.

### Phase 1 — Windows enforcement (2–4 days)

**Done when:** with one elevated command, browsing a blocked domain fails in Chrome/Edge without manual DNS setup.

- [ ] Bind `127.0.0.1:53` (admin required)
- [ ] Snapshot + set all active adapters’ DNS to `127.0.0.1` (IPv4; decide IPv6: set `::1` or disable DNS on IPv6 to avoid leaks)
- [ ] Restore DNS on `stop` and on panic path where possible
- [ ] Upstream resolver configurable (default `1.1.1.1`)
- [ ] Windows Service **or** elevated tray process that survives UI close
- [ ] Log path + simple `status`

**Demo script:** install → open blocked site → fails → open google.com → works → stop service → DNS restored.

### Phase 2 — Light anti-bypass (1–2 days)

**Done when:** `nslookup google.com 8.8.8.8` fails for normal users while filtering is on.

- [ ] Firewall rule: only `filterd.exe` may send outbound UDP/TCP 53
- [ ] Optional: block outbound TCP 853 except `filterd`
- [ ] Include a small static list of known DoH resolver hostnames in the block/allow policy (document as incomplete)
- [ ] Document residual bypass: custom DoH URL, VPN tunnel DNS, raw IPs, admin disable

### Phase 3 — Hardening only if time remains

- [ ] Adapter/Wi-Fi change watcher re-applies DNS
- [ ] List reload without restart
- [ ] Metrics: queries/sec, blocks/sec
- [ ] Browser extension handshake: “protection active” status (optional)
- [ ] macOS: **prototype** only (change DNS to localhost) labeled non-production
- [ ] Linux Ubuntu: systemd unit + NetworkManager DNS + nftables by UID

### Explicitly out of scope until after a working Windows demo

- Signed remote blocklist CDN  
- WFP callout drivers  
- Full Network Extension macOS product  
- VPN product modes  
- Local HTTPS block pages / root CA  
- Accountability “can’t uninstall”  
- Merging image/text ML classifiers into the DNS path  

---

## Matching and list rules (concrete)

```text
Input line:  ||sub.bad-site.example^
Stored:      sub.bad-site.example

Query:       a.b.sub.bad-site.example
Checks:      a.b.sub.bad-site.example
             b.sub.bad-site.example
             sub.bad-site.example   ← hit → BLOCK
```

- Categories: for v1, store `source` only (`nsfw` vs `tif.mini`); no ML confidence  
- Allowlist file: `allowlist.txt` exact/suffix overrides block  
- Memory: hundreds of thousands of strings is fine (~tens of MB)  
- Do **not** re-parse giant text files on every query; load once at start / reload  

---

## Risks and landmines (SPEC1 under-emphasizes)

1. **Port 53 conflicts** — Hyper-V, ICS, other DNS tools may own `:53`. Detect bind failure and show a clear error.  
2. **IPv6 DNS leak** — If only IPv4 DNS is set to localhost, apps may use IPv6 resolvers and bypass. Handle IPv6 explicitly.  
3. **DoH in browsers** — Chrome/Edge secure DNS bypasses your resolver. Mitigation: extension + group policy / documented disable, plus known DoH endpoint blocks (incomplete).  
4. **VPN** — Many VPNs push their own DNS inside the tunnel. v1: document “may not apply under VPN”; later detect tunnel adapters.  
5. **Restoring DNS** — A crash without restore = “no internet.” Prefer a scheduled restore task or write snapshot to disk and a tiny watchdog.  
6. **Admin rights** — Honest requirement on Windows for system DNS + firewall.  
7. **False positives** — Large NSFW lists will block edge domains; allowlist must be one command away.

---

## How this relates to the rest of your repo

| Piece | Role |
| --- | --- |
| `filterd` (this plan) | Device-wide **domain** enforcement |
| `dns-blocklists/` | Input data for filterd |
| `extension/` | Browser DoH/search/page/image layer; not a substitute for filterd |
| `text-classifier/`, `image-classifier/` | Content classification **inside** browser/extension flows, not DNS |

Do not wait on ML models to ship domain blocking. They solve a different problem (content on allowed domains).

---

## Success criteria for “it works”

Minimum demo (Windows):

1. Start filterd elevated with both lists loaded.  
2. System DNS points at `127.0.0.1`.  
3. A domain from `nsfw` list does not load in a normal browser session.  
4. A normal site still loads.  
5. Direct DNS to `8.8.8.8` is blocked (phase 2) or at least documented as phase 2.  
6. Stopping filterd restores previous DNS.  
7. README states clearly what is and is not blocked (no universal claims).

---

## Suggested first PR sequence

1. **Core library** — parse + match + unit tests (no network).  
2. **DNS proxy** — listen, block/forward on port 5353.  
3. **Windows DNS config** — set/restore adapters.  
4. **Wire to :53 + CLI** — end-to-end demo.  
5. **Firewall anti-bypass** — port 53 lockdown.  
6. **Service install** — auto-start.  

If a PR does not move you toward criteria 1–6 above, it is SPEC1-scope creep — cut it.

---

## Bottom line

- **Trust SPEC1 for architecture and honesty about limits.**  
- **Do not trust it as a build order** — it buries the MVP under product roadmap.  
- **Ship a Windows DNS filter service that loads your local HaGeZi lists, answers on localhost, rewrites system DNS, restores on exit, then tightens port-53 bypass.**  
- **Share the core; treat macOS/Linux as separate adapters, not day-one parity.**  
- **Keep classifiers and the extension as complementary layers, not dependencies of DNS blocking.**
