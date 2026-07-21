"""
Local classifier API for the EasyPeasy Chrome extension.

Endpoints:
  GET  /health
  POST /classify/text   { "text": "..." }
  POST /classify/image  { "url": "..." } or { "image_b64": "..." }

Uses the existing HuggingFace models under text-classifier/ and image-classifier/.
"""

from __future__ import annotations

import base64
import logging
import sys
import time
from pathlib import Path
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, Field

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "text-classifier"))
sys.path.insert(0, str(ROOT / "image-classifier"))

import text_classifier as text_clf  # noqa: E402
import image_categorizer as image_clf  # noqa: E402

log = logging.getLogger("classifier-api")
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")

app = FastAPI(title="EasyPeasy Classifier API", version="0.1.1")

# Extension service workers are CORS-exempt for host_permissions, but allow
# broad origins so popup / content-script debugging stays simple.
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

# In-process caches (url/text → result) so repeat navigations are instant.
_text_cache: dict[str, dict[str, Any]] = {}
_image_cache: dict[str, dict[str, Any]] = {}
CACHE_MAX = 2048


class TextRequest(BaseModel):
    text: str = Field(..., min_length=1, max_length=4000)


class ImageRequest(BaseModel):
    url: str | None = None
    image_b64: str | None = None


def _cache_put(cache: dict[str, dict[str, Any]], key: str, value: dict[str, Any]) -> None:
    if len(cache) >= CACHE_MAX:
        # Drop an arbitrary old entry (dict preserves insertion order).
        cache.pop(next(iter(cache)), None)
    cache[key] = value


def _fetch_image_bytes(url: str, timeout: float = 12.0) -> bytes:
    # Browser-like UA — many CDNs reject bare urllib UA.
    req = Request(
        url,
        headers={
            "User-Agent": (
                "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
                "AppleWebKit/537.36 (KHTML, like Gecko) "
                "Chrome/122.0.0.0 Safari/537.36"
            ),
            "Accept": "image/avif,image/webp,image/apng,image/*,*/*;q=0.8",
            "Accept-Language": "en-US,en;q=0.9",
        },
        method="GET",
    )
    try:
        with urlopen(req, timeout=timeout) as resp:
            data = resp.read()
    except HTTPError as exc:
        raise ValueError(f"HTTP {exc.code} fetching image") from exc
    except URLError as exc:
        raise ValueError(f"Network error fetching image: {exc.reason}") from exc
    except TimeoutError as exc:
        raise ValueError("Timeout fetching image") from exc

    if not data:
        raise ValueError("Empty image response")
    # Guard against accidental huge downloads.
    if len(data) > 15 * 1024 * 1024:
        raise ValueError("Image too large (>15MB)")
    return data


@app.get("/health")
def health() -> dict[str, Any]:
    return {
        "ok": True,
        "text_model": text_clf.MODEL_ID,
        "image_model": image_clf.MODEL_ID,
        "text_device": text_clf._device_label,
        "image_device": image_clf._device_label,
        "text_cache": len(_text_cache),
        "image_cache": len(_image_cache),
    }


@app.post("/warmup")
def warmup() -> dict[str, Any]:
    """Eager-load both models (first real request is otherwise slow)."""
    t0 = time.perf_counter()
    text_clf.get_pipeline()
    image_clf.get_model()
    return {
        "ok": True,
        "seconds": round(time.perf_counter() - t0, 2),
        "text_device": text_clf._device_label,
        "image_device": image_clf._device_label,
    }


@app.post("/classify/text")
def classify_text(body: TextRequest) -> dict[str, Any]:
    text = body.text.strip()
    if not text:
        raise HTTPException(status_code=400, detail="Empty text")

    cached = _text_cache.get(text)
    if cached is not None:
        return {**cached, "cached": True}

    try:
        t0 = time.perf_counter()
        result = text_clf.classify(text)
        ms = (time.perf_counter() - t0) * 1000
    except Exception as exc:
        log.exception("text classify failed")
        raise HTTPException(status_code=500, detail=str(exc)) from exc

    out = {
        "label": result["label"],
        "score": result["score"],
        "ms": round(ms, 1),
        "device": text_clf._device_label,
        "cached": False,
    }
    _cache_put(_text_cache, text, {k: v for k, v in out.items() if k != "cached"})
    return out


@app.post("/classify/image")
def classify_image(body: ImageRequest) -> dict[str, Any]:
    """
    Classify an image by URL or base64.

    On fetch/decode failures returns HTTP 200 with:
      { "ok": false, "keep": true, "error": "..." }
    so the extension can fail-open without treating it as a hard 500.
    Successful classifications return ok=true and the usual label fields.
    """
    if not body.url and not body.image_b64:
        raise HTTPException(status_code=400, detail="Provide url or image_b64")

    cache_key = body.url or f"b64:{hash(body.image_b64)}"
    cached = _image_cache.get(cache_key)
    if cached is not None:
        return {**cached, "cached": True}

    try:
        if body.image_b64:
            raw = body.image_b64
            if "," in raw and raw.strip().startswith("data:"):
                raw = raw.split(",", 1)[1]
            data = base64.b64decode(raw, validate=False)
        else:
            assert body.url is not None
            data = _fetch_image_bytes(body.url)

        t0 = time.perf_counter()
        result = image_clf.classify_bytes(data)
        ms = (time.perf_counter() - t0) * 1000
    except Exception as exc:
        # Soft-fail: do not 500 the extension for one bad CDN image.
        msg = str(exc)
        log.warning("image classify soft-fail url=%s err=%s", (body.url or "b64")[:120], msg)
        return {
            "ok": False,
            "keep": True,
            "error": msg,
            "label": "error",
            "score": 0.0,
            "cached": False,
        }

    out = {
        "ok": True,
        "keep": None,  # extension decides from label
        "label": result["label"],
        "score": result["score"],
        "scores": result.get("scores", {}),
        "ms": round(ms, 1),
        "device": image_clf._device_label,
        "cached": False,
    }
    _cache_put(_image_cache, cache_key, {k: v for k, v in out.items() if k != "cached"})
    return out


if __name__ == "__main__":
    import uvicorn

    # Bind localhost only — models stay on-machine.
    uvicorn.run(
        "server:app",
        host="127.0.0.1",
        port=8765,
        reload=False,
        log_level="info",
    )
