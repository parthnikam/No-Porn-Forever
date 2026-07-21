# Browser lockdown — what Windows can actually enforce

Goal: stop casual bypass via **Incognito / Guest / new profile / other browsers**.

This is **policy + OS DNS**, not magic inside one Load-unpacked extension.

## Capability matrix

| Capability | Chrome | Edge | Firefox | Opera | DuckDuckGo Browser |
|------------|--------|------|---------|-------|--------------------|
| Disable Guest mode | **Yes** (`BrowserGuestModeEnabled=0`) | **Yes** | N/A (no Guest) | **No** reliable policy | **No** |
| Disable Private / Incognito | **Yes** (`IncognitoModeAvailability=1`) | **Yes** | **Yes** (`DisablePrivateBrowsing`) | **No** | **No** |
| Force-install our extension | **Yes*** | **Yes*** | Only a **Firefox XPI port** | **No** | **No** |
| Force “Allow in Incognito” silently | **No** | **No** | N/A | N/A | N/A |
| Gate Incognito on extension allow | **Yes** (`MandatoryExtensionsForIncognitoNavigation`) | **Yes** | N/A | N/A | N/A |
| All profiles get force-installed add-on | **Yes*** (machine policy) | **Yes*** | If XPI forced | No | No |
| Block adding profiles | Partial (`BrowserAddPersonEnabled`) | Partial | Limited | No | No |
| Turn off Secure DNS (DoH) | **Yes** | **Yes** | Separate prefs | Weak | Weak |
| Domain block without extension | **filterd** (any browser using OS DNS) | same | same | same | same |

\*Force-install requires a **stable extension ID + CRX update URL** (Chrome Web Store, Edge Add-ons, or self-hosted update manifest).  
**“Load unpacked” cannot be force-installed** by enterprise policy.

## Recommended strategy

```text
1. filterd -protect          → device DNS floor (all browsers)
2. lock-browsers.ps1         → Chrome/Edge Guest off, Incognito off (or gated)
3. Publish CRX + ExtensionId → force-install NoPornForever on Chrome/Edge
4. Uninstall or IFEO-block   → Opera / DDG / Brave if you need “no escape hatch”
5. Optional AppLocker/WDAC   → real executable allow-list (strongest)
```

### Incognito: what “allow in Incognito” really means

Chrome **does not** let policy silently turn on “Allow in Incognito” for an extension in all versions. Practical options:

| Mode | Flag | Behavior |
|------|------|----------|
| **Disable** (recommended) | `-IncognitoMode Disable` | No Incognito at all — no extension-free private window |
| **Mandatory** | `-IncognitoMode Mandatory -ExtensionId …` | Incognito only works after user allows *this* extension in Incognito |
| **Leave** | `-IncognitoMode Leave` | User can still open Incognito without the extension |

## How to run

```powershell
# Admin PowerShell
cd extension\scripts

# Strongest without a store listing yet:
.\lock-browsers.ps1 -IncognitoMode Disable

# After you have a published extension ID:
.\lock-browsers.ps1 `
  -ExtensionId "YOUR32CHARIDFROMCHROME" `
  -UpdateUrl "https://clients2.google.com/service/update2/crx" `
  -IncognitoMode Disable

# Soft-block Opera / DuckDuckGo / Brave / Vivaldi processes:
.\lock-browsers.ps1 -IncognitoMode Disable -BlockUnmanagedBrowsers

# Undo
.\unlock-browsers.ps1
# or
.\lock-browsers.ps1 -Remove
```

Then **fully quit** every browser window and reopen. Check:

- `chrome://policy`
- `edge://policy`

## Finding your extension ID

1. `chrome://extensions` → Developer mode  
2. Load unpacked → copy **ID** under the extension card  
3. Note: unpacked IDs are path-dependent; a store/CRX build gets a permanent ID from the signing key  

For production force-install, pack with a permanent key / publish so the ID never changes.

## What is *not* solvable with REG ADD alone

1. **Unpacked force-install** across profiles  
2. **Silent Incognito injection** of the extension  
3. **Opera / DuckDuckGo** full policy parity with Chrome  
4. **One Chromium extension** running inside Firefox  
5. **Determined admin** with Admin rights (they can always undo registry / kill filterd)  
6. **Portable browsers** from a USB zip outside IFEO names  

For a true kiosk/accountability product you eventually want: Windows service (filterd) + AppLocker allow-list of browsers + force-installed CRX + disabled Incognito/Guest.

## Relation to filterd

| Layer | Escape if missing |
|-------|-------------------|
| filterd only | Safe search pages / user-generated NSFW on allowed domains |
| Extension only | Other profiles, Incognito, other browsers, disable add-on |
| Both + lock-browsers | Casual bypass much harder; admin bypass still possible |
