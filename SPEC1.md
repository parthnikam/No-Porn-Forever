The backbone should be a **privileged local network-enforcement service**, not an NPX package. The cross-platform part is the filtering engine and policy model; the operating-system integration must remain native.

# 1. The deployable architecture

```text
┌─────────────────────────────────────────────┐
│ Desktop UI                                 │
│ Settings, lock period, reports, exceptions │
└──────────────────────┬──────────────────────┘
                       │ authenticated local IPC
┌──────────────────────▼──────────────────────┐
│ Privileged background service              │
│                                             │
│  ┌──────────────┐   ┌────────────────────┐ │
│  │ DNS proxy    │   │ Policy engine      │ │
│  │ localhost:53 │◄──│ domains/categories │ │
│  └──────┬───────┘   └────────────────────┘ │
│         │                                   │
│  ┌──────▼────────────────────────────────┐ │
│  │ OS network-enforcement adapter        │ │
│  │ Windows WFP / macOS NE / Linux nft    │ │
│  └──────┬────────────────────────────────┘ │
└─────────┼───────────────────────────────────┘
          │
          ▼
Encrypted upstream DNS
DoH / DoT / regular DNS
```

The service performs four jobs:

1. Receive every normal DNS query from the device.
2. Check the requested domain against your local policy database.
3. Return `NXDOMAIN`, `0.0.0.0`, or a local block page for blocked domains.
4. Prevent applications from bypassing the local resolver.

The fourth part is what separates a real product from a hosts-file script.

---

# 2. The DNS filtering flow

Suppose an application requests:

```text
some-domain.example
```

The flow becomes:

```text
Application
    ↓
Operating-system DNS resolver
    ↓
127.0.0.1:53
    ↓
Your DNS proxy
    ↓
Normalize domain
    ↓
Check exact-domain rules
    ↓
Check parent-domain rules
    ↓
Check user allowlist
    ↓
Check blocklist/category database
    ↓
Allow or block
```

The matching logic should account for subdomains:

```text
Requested:
images.subdomain.example.com

Check:
images.subdomain.example.com
subdomain.example.com
example.com
```

A policy decision might look like:

```json
{
  "domain": "images.subdomain.example.com",
  "matched_rule": "example.com",
  "category": "adult",
  "source": "blocklist_3",
  "decision": "block"
}
```

Do not query a remote database for every request. Keep the domain database locally and update it periodically.

## Data structure

A few million domains can be handled locally using:

* A reversed-domain trie
* A compact hash set
* A minimal perfect hash structure
* SQLite for metadata plus an in-memory matching index

For the MVP, a normalized hash set is sufficient.

```text
example.com
adultsite.example
subdomain.example.org
```

Store categories and provenance separately:

```text
domain_id → category, source, confidence, updated_at
```

This lets you explain why something was blocked and resolve false positives.

---

# 3. DNS alone is not enough

Changing the operating-system DNS server to `127.0.0.1` catches ordinary DNS resolution, but applications can bypass it through:

```text
Application-managed DNS-over-HTTPS
Hard-coded DNS servers
Direct IP connections
VPN tunnels
Proxy applications
Tor-like tunnels
Alternative network namespaces
```

Therefore, the actual model must be:

```text
Local DNS proxy
        +
Network rule:
Only the filtering service may send external DNS
```

Conceptually:

```text
Allow:
filter-service.exe → upstream DNS

Block:
every other process → UDP/TCP port 53
every other process → known DoT port 853
```

This stops ordinary direct-DNS bypass.

DNS-over-HTTPS is harder because it travels over HTTPS port 443 and can look like ordinary web traffic. You can block known public DoH endpoints and disable secure DNS in browsers you control, but you cannot universally identify arbitrary DoH traffic without inspecting encrypted traffic or maintaining endpoint intelligence.

Your browser extension should therefore remain part of the system:

```text
System service:
Domain-level enforcement

Browser extension:
Secure-DNS control, search intent and page-level enforcement
```

---

# 4. Windows implementation

Windows provides Windows Filtering Platform, which exposes filtering hooks throughout the network stack and is specifically intended for network-filtering applications. ([Microsoft Learn][1])

Your Windows architecture should be:

```text
Windows Service
    ├── DNS proxy
    ├── Policy engine
    ├── WFP rule manager
    └── Local IPC server

Windows UI
    └── Communicates with service
```

## Stage 1: Feasible hackathon implementation

Install a Windows service that:

1. Starts automatically.
2. Listens locally for DNS.
3. Sets every active network adapter’s DNS server to localhost.
4. Restores previous settings during safe uninstall.
5. Adds firewall or WFP rules preventing other processes from reaching external DNS.
6. Watches for newly created adapters and reapplies DNS policy.

You must monitor adapter changes because connecting to Wi-Fi, Ethernet, a hotspot, or a VPN can create or reconfigure interfaces.

## Stage 2: Stronger Windows enforcement

Use WFP rules to control outbound connections. WFP’s filter engine performs filtering over TCP/IP traffic and supports conditions involving applications, interfaces, addresses and protocols. ([Microsoft Learn][2])

A practical policy is:

```text
Rule 1:
Allow filtering-service.exe to use external DNS

Rule 2:
Block all other outbound UDP port 53

Rule 3:
Block all other outbound TCP port 53

Rule 4:
Block TCP port 853 except filtering service

Rule 5:
Optionally block known DoH endpoints
```

Initially, these can be user-mode WFP filters. You do not need to immediately write a kernel callout driver.

A callout driver becomes relevant when you require packet inspection or behavior beyond standard WFP filtering. Microsoft describes callouts as extensions for more advanced TCP/IP processing. ([Microsoft Learn][3])

### Windows feasibility

| Capability                               |           Feasibility |
| ---------------------------------------- | --------------------: |
| Local DNS proxy                          |                  High |
| Force normal DNS through proxy           |                  High |
| Block direct DNS bypass                  |                  High |
| Block known DoH resolvers                |                Medium |
| Detect every custom DoH server           |                   Low |
| Work with ordinary VPNs                  |                Medium |
| Prevent an administrator uninstalling it | Impossible absolutely |
| Make impulsive disabling difficult       |                  High |

Windows should be your first production desktop target because it provides strong network filtering primitives and has a large consumer desktop user base.

---

# 5. macOS implementation

On macOS, the correct production API is Apple’s Network Extension framework, not manually modifying `/etc/hosts` or continuously rewriting DNS configuration.

Apple provides:

* DNS proxy providers that can take responsibility for system DNS resolution
* Content-filter providers that can allow or deny network flows
* Network Extension configuration and deployment mechanisms ([Apple Developer][4])

Apple documents macOS DNS proxy providers as system extensions from macOS 10.15 onward. ([Apple Developer][5])

The macOS version would look like:

```text
Main macOS application
        │
        ├── Settings UI
        ├── Account/login
        └── Extension configuration
                │
                ▼
Network System Extension
        ├── DNS proxy provider
        └── Optional content filter provider
```

The DNS proxy receives system DNS requests and can forward allowed queries using DoH or DoT. Apple explicitly describes DNS proxy providers as resolving system queries and forwarding them to upstream DNS services. ([Apple Developer][6])

## Important macOS consequence

Your cross-platform service cannot simply be compiled unchanged for macOS. The filtering core can be shared, but the operating-system entry point must be a signed Apple system extension with the proper Network Extension entitlement. ([Apple Developer][7])

Distribution requires:

* Apple Developer signing
* Notarization
* Proper entitlements
* User approval of the system extension
* Native Swift or Objective-C integration

For the hackathon, macOS can be represented through a lighter adapter that changes DNS settings, but that should be labelled a prototype. The system-extension version is the production path.

---

# 6. Linux implementation

Linux is not one uniform desktop networking environment. Different distributions may use:

* `systemd-resolved`
* NetworkManager
* `resolvconf`
* Direct `/etc/resolv.conf`
* Container or namespace-specific DNS

On systems using `systemd-resolved`, a local stub listener is normally exposed at `127.0.0.53` and `127.0.0.54`. ([Freedesktop][8])

A Linux implementation could run:

```text
filterd system service
    ├── DNS proxy on local address
    ├── systemd-resolved integration
    ├── NetworkManager integration
    └── nftables enforcement
```

`nftables` provides Linux’s in-kernel packet classification and filtering framework over the Netfilter subsystem. ([netfilter.org][9])

Your nftables policy would conceptually be:

```text
Allow external DNS from filterd UID
Block UDP/TCP 53 from other processes
Block TCP 853 from other processes
Redirect permitted local DNS queries to filterd
```

Linux also supports transparent proxying through Netfilter/nftables, although it requires policy routing and adds substantial complexity. ([Linux Kernel Documentation][10])

### Linux feasibility problem

Linux is technically powerful but operationally fragmented. You will need separate integration paths for at least:

```text
Ubuntu/Debian + systemd-resolved
Fedora + NetworkManager
Arch-like distributions
```

For initial public distribution, support Ubuntu explicitly rather than claiming support for all Linux distributions.

---

# 7. How VPNs affect the system

There are several different VPN configurations.

## Case A: VPN changes only DNS

```text
Application
    ↓
VPN-configured DNS
    ↓
VPN provider
```

Your service must detect the VPN adapter and reapply your resolver policy. This is feasible on desktop, although some VPN clients may continually overwrite the setting.

## Case B: Full-tunnel VPN

```text
Application traffic
    ↓
VPN virtual adapter
    ↓
Encrypted tunnel
    ↓
VPN server
```

Whether your filter sees DNS before or after the VPN depends on:

* Operating-system routing order
* VPN implementation
* Split-tunnel versus full-tunnel mode
* Whether the VPN performs its own DNS resolution
* Whether it uses a virtual adapter, kernel driver or userspace tunnel

You cannot promise universal compatibility with every VPN.

## Case C: VPN application uses embedded DoH

The VPN client may resolve its own endpoints over HTTPS or send all resolution through the encrypted tunnel. Your local DNS proxy may never see those requests.

## Case D: Your application is the VPN

This gives you the most predictable routing:

```text
Device
    ↓
Your tunnel/filter
    ↓
Optional upstream privacy VPN
    ↓
Internet
```

However, building and operating a VPN service is a much larger product:

* VPN protocol implementation or integration
* Server infrastructure
* Bandwidth costs
* Privacy and security responsibilities
* Geographic server deployment
* Abuse handling
* Considerably higher operational risk

For desktop, do not start by becoming a VPN provider.

---

# 8. The realistic VPN strategy

Use three compatibility modes.

## Standard mode

```text
Local DNS proxy
+
OS firewall enforcement
+
Known DoH blocking
+
Browser extension
```

This works with ordinary networking and some VPN configurations.

## Strict mode

When an unknown tunnel or proxy adapter appears:

```text
New tunnel detected
        ↓
Verify compatibility
        ↓
Compatible → apply DNS policy
Incompatible → block traffic or warn user
```

Strict mode can provide:

```text
“Protection cannot be verified while this VPN is active.”
```

The user can choose:

* Disable the VPN
* Use a supported VPN configuration
* Temporarily lose network access
* Request an accountability-approved exception

## Supported-VPN mode

Create tested integrations for selected VPNs rather than claiming every VPN works.

For example:

```text
VPN provider A:
Use custom DNS setting → localhost

WireGuard:
Configure DNS in profile

OpenVPN:
Override pushed DNS where possible
```

This is a product-maintenance problem, not merely a one-time coding problem.

---

# 9. Cross-platform code structure

A sensible implementation language is Rust.

```text
/core
    domain_normalization.rs
    blocklist_index.rs
    policy_engine.rs
    dns_protocol.rs
    upstream_resolver.rs
    telemetry.rs

/platform/windows
    service.rs
    adapter_manager.rs
    wfp.rs
    installer.rs

/platform/macos
    app.swift
    dns_proxy_extension.swift
    content_filter_extension.swift

/platform/linux
    daemon.rs
    systemd_resolved.rs
    network_manager.rs
    nftables.rs

/ui
    Tauri or native frontend

/extension
    Chrome/Firefox extension
```

Rust is useful here because:

* The DNS and policy core can compile across platforms.
* It is suitable for long-running native services.
* It has low runtime overhead.
* It avoids requiring users to install Python or Node.
* Tauri can expose a desktop UI over the same native backend.

The browser extension remains TypeScript.

```text
Shared:
Rust domain engine
Blocklist format
Policy format
Update protocol
Telemetry format

OS-specific:
Installation
Privileges
DNS configuration
Firewall integration
Service lifecycle
Tamper handling
```

That is the correct interpretation of “cross-platform”: shared logic with native enforcement adapters.

---

# 10. Installation and distribution

The user should not run terminal commands.

## Windows

Ship a signed `.msi` or `.exe` installer that:

```text
1. Requests administrator permission.
2. Installs the service.
3. Installs the UI.
4. Stores previous DNS configuration.
5. Configures firewall/WFP rules.
6. Starts the service.
7. Installs or links the browser extension.
8. Registers the uninstaller.
```

## macOS

Ship a signed and notarized `.pkg` or `.dmg` containing:

```text
Main app
Network system extension
Extension activation flow
Browser extension
```

## Linux

Initially provide:

```text
.deb package for Ubuntu
systemd service
NetworkManager/systemd-resolved integration
nftables setup
```

Do not begin with Snap, Flatpak or AppImage for the enforcement service. Their sandboxing models are not naturally suited to installing privileged system networking components. You can eventually package the UI separately, but the daemon still needs native installation.

---

# 11. Blocklist update pipeline

Do not have every client independently download and parse arbitrary third-party lists.

Use a backend compilation pipeline:

```text
Raw blocklists
    ↓
Download and verify
    ↓
Parse formats
    ↓
Normalize domains
    ↓
Remove invalid entries
    ↓
Deduplicate
    ↓
Apply allowlist
    ↓
Attach categories and provenance
    ↓
Generate signed release
    ↓
Clients download incremental update
```

Inputs may contain:

```text
0.0.0.0 domain.example
127.0.0.1 domain.example
domain.example
*.domain.example
||domain.example^
```

Normalize everything into a canonical domain representation.

Your release format might be:

```json
{
  "version": 184,
  "generated_at": "2026-07-21T18:00:00Z",
  "domain_count": 1823456,
  "sha256": "...",
  "signature": "...",
  "download_url": "..."
}
```

The client should verify the signature before replacing its active blocklist.

Use atomic updates:

```text
Download new index
    ↓
Verify checksum and signature
    ↓
Load and test
    ↓
Rename into active location
    ↓
Keep previous version for rollback
```

This prevents a corrupted update from breaking the user’s internet connection.

---

# 12. Avoid returning `0.0.0.0` for everything

There are three common blocking responses:

## `NXDOMAIN`

Claims the domain does not exist.

```text
Advantages:
Simple
No extra connection

Disadvantages:
Some applications retry another resolver
No branded block page
```

## `0.0.0.0` or `::`

Routes nowhere.

```text
Advantages:
Simple

Disadvantages:
Produces unclear browser errors
Different application behavior
```

## Local block-page address

Return a local IP controlled by your service.

```text
Blocked domain
    ↓
DNS returns local address
    ↓
Browser connects to local web server
    ↓
Intervention page
```

This works cleanly only for HTTP. With HTTPS, the browser expects a certificate valid for the requested domain. Your local server cannot provide that certificate, so the user sees a TLS certificate error.

Do not install a local root CA and perform HTTPS interception for this product. That would greatly increase security risk and complexity.

Instead:

* Let DNS-blocked HTTPS sites fail normally.
* Let the extension recognize the block event or domain and display the intervention UI.
* Use local redirect pages primarily for browser-extension initiated blocks.

---

# 13. Preventing the product from breaking the internet

A system DNS product needs fail-safe behavior.

```text
Service healthy:
Use local filtering resolver

Service crashed:
Choose policy:
    fail-open → internet continues unfiltered
    fail-closed → internet stops
```

Provide both modes:

* **Normal mode:** fail open after a short recovery attempt.
* **Strict commitment mode:** fail closed until the service restarts.

You also need:

```text
Watchdog service
DNS health check
Upstream resolver fallback
Emergency recovery command
Automatic configuration rollback
Safe mode detection
Captive portal handling
```

Captive portals are important. Hotel and airport Wi-Fi may require access to a local login domain that is not publicly resolvable in the ordinary way.

Your resolver should detect likely captive-portal conditions and temporarily permit the operating system’s connectivity-check flow without disabling the entire filter.

---

# 14. Recommended development stages

## Phase 1: Hackathon backbone

Build on Windows first:

```text
Rust Windows service
Local DNS proxy
Compiled blocklist
Adapter DNS configuration
Basic firewall rules
Chrome extension integration
Tauri dashboard
```

Demo:

1. Install with one executable.
2. Activate protection.
3. Open any browser.
4. Known blocked domains fail before loading.
5. Changing Wi-Fi does not disable filtering.
6. Direct requests to `8.8.8.8:53` are blocked.
7. The extension handles mixed-content websites and intervention UI.
8. Killing the UI does not stop the service.

## Phase 2: Windows production hardening

Add:

```text
WFP-based enforcement
Service watchdog
Signed updates
VPN adapter detection
Strict mode
Tamper events
Accountability control
Firefox support
```

## Phase 3: macOS

Build the native Network Extension implementation.

## Phase 4: Linux

Support Ubuntu with `.deb`, systemd and nftables.

---

# 15. What the first product should claim

Do not claim:

> It blocks pornography on every operating system, through every VPN, and cannot be bypassed.

Claim:

> It enforces device-wide adult-domain filtering through a privileged local DNS service, prevents common DNS bypass methods, detects incompatible VPNs and adds browser-level classification for content hosted on mixed platforms.

The complete system is:

```text
                    ┌─────────────────────┐
                    │ Browser extension   │
                    │ Query/page/image    │
                    └──────────┬──────────┘
                               │
┌──────────────┐      ┌────────▼──────────┐
│ Desktop UI   │─────►│ Privileged daemon │
└──────────────┘      │                    │
                      │ DNS proxy          │
                      │ Policy engine      │
                      │ Blocklist index    │
                      │ VPN detection      │
                      │ Update client      │
                      └────────┬───────────┘
                               │
             ┌─────────────────┼─────────────────┐
             ▼                 ▼                 ▼
       Windows WFP       macOS Network      Linux nftables
                         Extension
```

For the hackathon, I would implement **Windows + Chrome completely**, design the shared Rust core so macOS and Linux adapters can be added later, and demonstrate VPN detection rather than pretending universal VPN enforcement already exists.

[1]: https://learn.microsoft.com/en-us/windows/win32/fwp/windows-filtering-platform-start-page?utm_source=chatgpt.com "Windows Filtering Platform - Win32 apps"
[2]: https://learn.microsoft.com/en-us/windows-hardware/drivers/network/windows-filtering-platform-architecture-overview?utm_source=chatgpt.com "Windows Filtering Platform Architecture Overview"
[3]: https://learn.microsoft.com/en-us/windows-hardware/drivers/network/introduction-to-windows-filtering-platform-callout-drivers?utm_source=chatgpt.com "Introduction to Windows Filtering Platform Callout Drivers"
[4]: https://developer.apple.com/documentation/networkextension?utm_source=chatgpt.com "Network Extension | Apple Developer Documentation"
[5]: https://developer.apple.com/documentation/technotes/tn3134-network-extension-provider-deployment?utm_source=chatgpt.com "TN3134: Network Extension provider deployment"
[6]: https://developer.apple.com/documentation/networkextension/nednsproxyprovider?utm_source=chatgpt.com "NEDNSProxyProvider | Apple Developer Documentation"
[7]: https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.networking.networkextension?utm_source=chatgpt.com "Network Extensions Entitlement"
[8]: https://www.freedesktop.org/software/systemd/man/systemd-resolved.service.html?utm_source=chatgpt.com "systemd-resolved.service"
[9]: https://www.netfilter.org/projects/nftables/index.html?utm_source=chatgpt.com "The netfilter.org \"nftables\" project"
[10]: https://docs.kernel.org/networking/tproxy.html?utm_source=chatgpt.com "Transparent proxy support"
