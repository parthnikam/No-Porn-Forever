# EasyPeasy Content Guard (browser extension)

Three browser layers on top of system DNS (`filterd`):

| Layer | What it does |
|-------|----------------|
| **Domain list** | Blocks hosts from `nsfw.txt` (works even under VPN extensions) |
| **Search / URL text** | Reads search queries from the navigation URL → local text classifier → blocks NSFW searches |
| **Images** | Classifies page images → removes anything not labeled **Normal** |

ML inference does **not** run inside Chrome. A small local API loads your existing HuggingFace models:

```text
extension  →  http://127.0.0.1:8765  →  text-classifier / image-classifier
```

## Why URL (not the omnibox keystrokes)

Chrome extensions cannot read the address bar as you type. Once you submit a search, the URL becomes something like:

```text
https://www.google.com/search?q=your+query
https://duckduckgo.com/?q=your+query
https://www.bing.com/search?q=your+query
```

The extension watches `webNavigation`, extracts `q` / `query` / …, classifies that string, and redirects to the block page if the model returns **nsfw**.

## Install

### 1) Start the classifier API (required for text + images)

```powershell
cd classifier-api
# use your env that already has torch/transformers, e.g. py3.10
conda activate py3.10
pip install -r requirements.txt   # first time
.\run.ps1
```

Optional warmup (loads both models immediately):

```powershell
# other terminal
curl -X POST http://127.0.0.1:8765/warmup
```

### 2) Sync domain list + load extension

```powershell
cd extension
.\scripts\sync-list.ps1
```

Chrome → `chrome://extensions` → **Developer mode** → **Load unpacked** → select this `extension/` folder.

(Edge: `edge://extensions`, same steps.)

### 3) Verify popup

Open the extension popup:

- **List: ready** — domain blocklist loaded  
- **Classifier API: online** — text + image filtering active  

If the API is offline, domain blocking still works; text/image layers fail open (do not brick browsing).

## How image filtering works

1. Content script finds `<img>` elements (skips tiny icons &lt; 48px).
2. Sends image URL to the service worker → `POST /classify/image`.
3. Local server downloads the image and runs `strangerguardhf/nsfw_image_detection`.
4. Labels other than **Normal** are removed / blanked (`Hentai`, `Pornography`, `Enticing or Sensual`, `Anime Picture`, …).

## Limits (honest)

- First model load is slow (tens of seconds); keep the API running.
- Search block can flash the results page for a moment while the async classify finishes (then redirects).
- Some sites block server-side image downloads (hotlink protection) — those images are left alone (fail-open).
- Cross-origin canvas capture is avoided; the API fetches by URL instead.
- Users can disable the extension unless you lock it with enterprise policy.
- Pair with **filterd** for device-wide DNS blocking outside the browser.

## Use with filterd

| Layer | Covers |
|-------|--------|
| `filterd run -protect` | Whole OS DNS, most apps |
| **Content Guard extension** | Browser domains + search text + page images |

Use **both**.

## Lock browsers (Incognito / Guest / multi-profile)

A normal install is **per profile**. To push machine policy (Admin):

```powershell
# Elevated PowerShell — disable Guest + Incognito on Chrome/Edge
cd extension\scripts
.\lock-browsers.ps1 -IncognitoMode Disable

# After you publish a CRX / have a stable ID, also force-install:
.\lock-browsers.ps1 -ExtensionId "your32charid" -IncognitoMode Disable

# Soft-block Opera / DuckDuckGo / Brave / Vivaldi processes:
.\lock-browsers.ps1 -IncognitoMode Disable -BlockUnmanagedBrowsers

.\unlock-browsers.ps1   # undo
```

See [`docs/BROWSER_LOCKDOWN.md`](../docs/BROWSER_LOCKDOWN.md) for the honest matrix (what REG/policy can and cannot do).
