# iOS FilterDnsExtension (Network Extension scaffold)

This folder is the **iOS equivalent** of:

| Platform | Enforcement |
|----------|-------------|
| Windows desktop | `filterd` service + system DNS |
| Android | `FilterVpnService` (`VpnService`) |
| iOS | **This** Packet Tunnel / DNS Proxy extension |

## Why Flutter/Dart alone is not enough on iOS

Apple does **not** allow a normal app to become the system DNS resolver.
You must ship a **Network Extension** (separate process, separate target) with:

1. Paid Apple Developer Program membership  
2. App ID capability: **Network Extensions** → Packet Tunnel and/or DNS Proxy  
3. App Group (e.g. `group.com.NoPornForever.filterd`) to share `nsfw.txt` with the host app  
4. User approval of the VPN/DNS profile in Settings  

The Flutter UI (island, stats, list test) is shared. Only the tunnel is native.

## Xcode wiring (when you have a Mac + team)

1. Open `ios/Runner.xcworkspace` in Xcode.  
2. **File → New → Target → Network Extension → Packet Tunnel Provider**.  
3. Product name: `FilterDnsExtension`  
4. Bundle ID: `com.NoPornForever.filterdMobile.FilterDnsExtension`  
5. Replace generated provider with `PacketTunnelProvider.swift` from this folder.  
6. Add App Group `group.com.NoPornForever.filterd` to **Runner** and **FilterDnsExtension**.  
7. Copy `assets/nsfw.txt` into the extension bundle or App Group container on first launch.  
8. Set host app `NoPornForeverNEConfigured = YES` in Info.plist when ready so the UI reports `vpnImplemented: true`.

### Optional: DNS Proxy Provider

For DNS-only (closer to desktop `filterd`), prefer **DNS Proxy** entitlement when available to your account. Packet Tunnel is more widely documented and is what the scaffold implements.

## Judge talking points

- **Same product architecture** as Android/desktop: privileged DNS path + shared blocklist.  
- **UI is cross-platform Flutter**; **enforcement is always OS-native**.  
- iOS is **not “unsupported”** — it is **capability-gated** by Apple, not by our design.  
- Android demo runs today without special developer programs beyond normal sideloading.

## What works without the extension

- Full Flutter UI + floating protection island (in-app)  
- Dart `DomainEngine` list check (same parent-label rules as `filterd`)  
- Clear error when Start is pressed without NE provisioning  
- Capabilities card explains iOS status honestly  
