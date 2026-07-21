# NoPornForever — Mobile (Flutter)

Device-wide **NSFW DNS filter** for phones — the mobile counterpart of desktop [`filterd`](../filterd/).

## Can Dart make a VPN?

**Partially — and that’s the right answer.**

| Layer | Dart / Flutter? | Why |
|-------|-----------------|-----|
| Blocklist parse + parent-label match | **Yes** | Pure Dart (`lib/core/`) — same rules as `filterd` |
| Floating “protection island” UI | **Yes** | Flutter |
| Stats / test domain / branding | **Yes** | Flutter |
| Become system DNS / own traffic | **No — OS native only** | Android `VpnService`, iOS Network Extension |

So: **Dart is capable of the product brain**, not of replacing the OS network stack.  
This is the same split as desktop (`filterd` Go core + Windows service adapters).

```text
Flutter UI + Dart DomainEngine
        │  MethodChannel
        ▼
┌───────────────────┬────────────────────────────┐
│ Android           │ iOS                        │
│ FilterVpnService  │ FilterDnsExtension         │
│ (VpnService)      │ (Network Extension)        │
│ FULL for demo     │ Scaffold + judge messaging │
└───────────────────┴────────────────────────────┘
        same assets/nsfw.txt as desktop
```

## Platforms for judges

| | Android | iOS |
|--|---------|-----|
| UI + island | Yes | Yes |
| List check (Dart) | Yes | Yes |
| Device DNS filter | **Yes — local VPN** | Scaffolded — needs Apple **Network Extension** entitlement + paid developer team |
| System overlay bubble | Permission ready | Not allowed (in-app island only) |

**Demo path:** Android phone + Windows `filterd`.  
**iOS story:** “Same architecture; Apple requires a signed Network Extension — scaffold is in-repo under `ios/FilterDnsExtension/`.”

## Run (Android)

```powershell
cd mobile
flutter pub get
flutter test
flutter run -d <android-device-or-emulator>
```

1. Tap **Start protection**  
2. Accept the system **VPN connection** dialog  
3. Browse a blocked domain → should fail to resolve  
4. Island shows **Protected** + blocked count  
5. Foreground notification keeps the tunnel alive  

## Run (iOS)

```bash
cd mobile
flutter pub get
flutter run -d <ios-simulator-or-device>
```

- UI, island, and Dart list test work in the simulator.  
- **Start protection** returns a clear entitlement message until you wire the Packet Tunnel target (see [`ios/FilterDnsExtension/README.md`](ios/FilterDnsExtension/README.md)).

## Project layout

```text
mobile/
  lib/
    core/           # Dart list parser + DomainEngine (filterd parity)
    services/       # FilterVpn MethodChannel API
    ui/             # Protection island + home
  assets/
    nsfw.txt        # HaGeZi NSFW list (~115k domains)
    allowlist.txt
  android/.../FilterVpnService.kt   # real local DNS VPN
  ios/FilterDnsExtension/           # NE scaffold + judge docs
```

## ML Guardian (Classifier API)

The phone does **not** ship the heavy HuggingFace models. It calls the same
local **`classifier-api`** the Chrome extension uses:

| Signal | Action |
|--------|--------|
| Typed text → `/classify/text` → `nsfw` | Lock screen + **close app** |
| Screen JPEG (Android MediaProjection) → `/classify/image` | Lock + close if Pornography / Hentai / Enticing |
| Safe Browser URL / search + WebView snapshots | Close page flow via same guardian |

### Wire phone → PC API

1. On the PC (repo root):

   ```powershell
   # Bind on LAN so the phone can reach you
   $env:NOPORNFOREVER_API_HOST = "0.0.0.0"
   cd classifier-api
   python launch.py
   ```

   Or write `%ProgramData%\NoPornForever\classifier-api\config.json`:

   ```json
   { "host": "0.0.0.0", "port": 8765, "warmup": true }
   ```

2. Allow Windows Firewall inbound TCP **8765** (private network).

3. In the app → **ML Guardian** → set base URL:

   | Device | URL |
   |--------|-----|
   | Android emulator | `http://10.0.2.2:8765` (default) |
   | Physical phone | `http://<your-pc-lan-ip>:8765` |

4. Toggle **Enable guardian**, accept **screen capture** permission (Android).

5. Demo:

   - Type explicit intent in the trap box → app locks and exits  
   - Open **Safe Browser**, search NSFW → text/image path trips  
   - With guardian on, open NSFW full-screen → screen scan trips  

### Limits (be honest with judges)

- Models run on the **PC API**, not offline on-device (battery/size).  
- Screen capture is **Android MediaProjection** (user consent). iOS cannot scan other apps; use Safe Browser snapshots.  
- “Close the website” for Chrome/Safari requires OS MDM / browser integration — we demo via **Safe Browser** + **app exit**.  
- Fail-open if API is unreachable (won’t brick typing).  

## Honesty (same as desktop)

- Real remote VPNs can own DNS inside their tunnel  
- Custom DoH / hard-coded IPs can bypass DNS filters  
- Not “unkillable” without MDM / Always-on VPN lockdown  

## Pair with desktop

| Surface | Path |
|---------|------|
| Windows service | `filterd/` |
| Browser ML layers | `extension/` + `classifier-api/` |
| Mobile DNS + ML guardian | **this app** |
