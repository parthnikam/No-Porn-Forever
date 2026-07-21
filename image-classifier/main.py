"""
NSFW image classifier using Falconsai/nsfw_image_detection.

Labels: "normal" | "nsfw"
"""

from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

import torch
from PIL import Image
from transformers import pipeline


MODEL_ID = "Falconsai/nsfw_image_detection"

# Lazy-loaded so import-only usage stays cheap until first classify() call.
_pipe = None
_device_label = "cpu"


def resolve_device() -> tuple[int | str, torch.dtype, str]:
    """Prefer CUDA + float16 when available (faster load + inference)."""
    if torch.cuda.is_available():
        name = torch.cuda.get_device_name(0)
        return 0, torch.float16, f"cuda:0 ({name})"
    return -1, torch.float32, "cpu"


def get_pipeline():
    global _pipe, _device_label
    if _pipe is None:
        device, dtype, _device_label = resolve_device()
        print(f"Loading model: {MODEL_ID} on {_device_label} ...", file=sys.stderr)
        t0 = time.perf_counter()
        _pipe = pipeline(
            "image-classification",
            model=MODEL_ID,
            device=device,
            dtype=dtype,
            model_kwargs={"low_cpu_mem_usage": True},
        )
        if device != -1:
            torch.backends.cuda.matmul.allow_tf32 = True
        print(
            f"Model ready in {time.perf_counter() - t0:.2f}s on {_device_label}.",
            file=sys.stderr,
        )
    return _pipe


def classify(image_path: str | Path) -> dict:
    """
    Classify a single image file.

    Returns:
        {
            "label": "normal"|"nsfw",
            "score": float in [0, 1],
            "scores": {"normal": float, "nsfw": float},
        }
    """
    path = Path(image_path)
    if not path.is_file():
        raise FileNotFoundError(f"Image not found: {path}")

    with Image.open(path) as img:
        img = img.convert("RGB")
        results = get_pipeline()(img)

    # pipeline returns a list of {label, score}, sorted by score desc
    scores = {item["label"]: float(item["score"]) for item in results}
    top = results[0]
    return {
        "label": top["label"],
        "score": float(top["score"]),
        "scores": scores,
    }


def format_result(image_path: str | Path, result: dict) -> str:
    label = result["label"]
    score = result["score"]
    return f"[{label.upper()}] score={score:.4f}  |  {image_path}"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Classify an image as normal or nsfw (GPU when available).",
    )
    parser.add_argument(
        "images",
        nargs="*",
        help="Path(s) to image file(s). If omitted, prompts interactively.",
    )
    parser.add_argument(
        "-j",
        "--json",
        action="store_true",
        help="Print raw JSON result instead of a human-readable line.",
    )
    args = parser.parse_args(argv)

    if args.images:
        paths = args.images
    elif not sys.stdin.isatty():
        paths = [line.strip() for line in sys.stdin if line.strip()]
        if not paths:
            print("No image paths received on stdin.", file=sys.stderr)
            return 1
    else:
        try:
            user = input("Enter path to image: ").strip().strip('"')
        except EOFError:
            print("No input.", file=sys.stderr)
            return 1
        if not user:
            print("Empty input.", file=sys.stderr)
            return 1
        paths = [user]

    # Load once before the loop (also warms CUDA kernels).
    get_pipeline()

    exit_code = 0
    for image_path in paths:
        try:
            t0 = time.perf_counter()
            result = classify(image_path)
            infer_s = time.perf_counter() - t0
        except Exception as exc:
            print(f"Error classifying {image_path}: {exc}", file=sys.stderr)
            exit_code = 1
            continue

        if args.json:
            print(
                json.dumps(
                    {"image": str(image_path), "device": _device_label, **result},
                    ensure_ascii=False,
                )
            )
        else:
            print(format_result(image_path, result))
            print(f"(inference {infer_s * 1000:.1f} ms on {_device_label})", file=sys.stderr)

    return exit_code


if __name__ == "__main__":
    raise SystemExit(main())
