# Classifier API

Local HTTP API that loads the repo’s HuggingFace models so the Chrome extension
can classify **search text** and **page images** without shipping models into
the browser.

```text
POST /classify/text   { "text": "..." }
POST /classify/image  { "url": "https://..." }  or  { "image_b64": "..." }
GET  /health
POST /warmup
```

Listens on **`http://127.0.0.1:8765`** only.

## Run

```powershell
conda activate py3.10
cd classifier-api
pip install -r requirements.txt
.\run.ps1
```

First request (or `/warmup`) downloads/loads models — can take 30–90s. GPU is used when CUDA is available (same logic as the CLI scripts).

## Smoke test

```powershell
curl http://127.0.0.1:8765/health
curl -X POST http://127.0.0.1:8765/classify/text -H "Content-Type: application/json" -d "{\"text\":\"hello world\"}"
```
