# Classifier API (always-on for the extension)

Local HTTP API on **`http://127.0.0.1:8765`** that loads the repo HuggingFace models so the Chrome extension can classify search text and page images.

## End user: install once

1. Use a Python env that already has the deps (e.g. `conda` env `py3.10`):

   ```powershell
   conda activate py3.10
   cd classifier-api
   pip install -r requirements.txt
   ```

2. Double-click **`INSTALL.bat`** (or run `.\install.ps1`).

3. Done. The API:

   - Starts **now**
   - Starts again at **every Windows logon** (and at startup)
   - **Restarts** if it crashes (Task Scheduler, 5 retries)
   - Logs to `%ProgramData%\EasyPeasy\classifier-api\classifier-api.log`

Uninstall: **`UNINSTALL.bat`**.

### Check it’s up

```powershell
Invoke-RestMethod http://127.0.0.1:8765/health
```

Extension popup should show **Classifier API: online**.

## Dev (foreground, no task)

```powershell
conda activate py3.10
cd classifier-api
python launch.py
# or: python server.py
```

## Endpoints

| Method | Path | Body |
|--------|------|------|
| GET | `/health` | — |
| POST | `/warmup` | — |
| POST | `/classify/text` | `{ "text": "..." }` |
| POST | `/classify/image` | `{ "url": "..." }` or `{ "image_b64": "..." }` |

## Why a scheduled task (not only a service)?

The image/text models want **GPU + your user HuggingFace cache**. A task that runs **at logon as your user** sees CUDA correctly. A LocalSystem service often falls back to CPU or can’t see the GPU.

| Piece | Location |
|-------|----------|
| Code | this folder (`launch.py`, `server.py`) |
| Config | `%ProgramData%\EasyPeasy\classifier-api\config.json` |
| Log | `%ProgramData%\EasyPeasy\classifier-api\classifier-api.log` |
| Task | Task Scheduler → `EasyPeasyClassifierAPI` |

## Pair with the extension

```text
INSTALL.bat (this API)  →  always-on ML backend
Load unpacked extension →  UI / block / image filter
filterd INSTALL.bat     →  device-wide domain DNS
```

All three together are the full product stack.
