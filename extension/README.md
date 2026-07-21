# EasyPeasy Domain Guard (browser extension)

Blocks NSFW domains **inside Chrome/Edge**, including when a **VPN extension**
proxies traffic and bypasses system DNS (`filterd`).

## Why DNS alone is not enough

```text
Normal site:
  Browser → OS DNS (filterd) → blocked ✓

With VPN extension:
  Browser → VPN proxy in the cloud → remote DNS → site loads ✗
  filterd never sees the query
```

VPN extensions do not remove the destination URL from the browser. This
extension watches navigations and redirects blocked hosts to a local block page.

```text
Browser VPN path:
  Navigation to pornhub.com
       ↓
  Domain Guard (this extension) → BLOCK page ✓
       ↓ (never completes)
  VPN proxy
```

## Install (Chrome / Edge)

```powershell
# 1) Copy nsfw.txt into the extension folder
cd extension
.\scripts\sync-list.ps1

# 2) Chrome → chrome://extensions
#    Enable "Developer mode"
#    "Load unpacked" → select this `extension` folder

# Edge → edge://extensions  (same steps)
```

## Use with filterd

| Layer | Covers |
|-------|--------|
| `filterd run -protect` | Whole OS DNS, most apps |
| **Domain Guard extension** | Browser + VPN extensions + Secure DNS edge cases |

Use **both**. DNS cannot see inside a browser VPN tunnel; the extension can.

## After install

1. Keep Domain Guard **enabled**.
2. If a VPN extension is on, the popup will say so — blocking still applies.
3. Fully restart the browser after installing.
4. Re-run `.\scripts\sync-list.ps1` when you update `filterd/nsfw.txt`, then click **Reload blocklist** in the popup (or reload the extension).

## Limits (honest)

- Only blocks in browsers where the extension is installed.
- A determined user can disable the extension unless you lock it with enterprise policy / OS controls.
- Non-browser VPN apps (WireGuard, OpenVPN clients) still need OS-level strategy (detect/warn; full tunnel VPN is hard).
- Very large lists take ~1–2s to parse on first load.

## Optional: force direct proxy via Windows policy

`filterd run -protect` can set Chrome/Edge proxy mode to `direct` so many VPN
extensions cannot take over the proxy. That is aggressive (breaks corporate
proxies). Prefer the extension URL-block approach first.
