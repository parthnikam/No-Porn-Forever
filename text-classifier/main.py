"""
NSFW text classifier using eliasalbouzidi/distilbert-nsfw-text-classifier.

Labels: "safe" | "nsfw"
"""

from __future__ import annotations

import argparse
import json
import sys
import time

import torch
from transformers import pipeline


MODEL_ID = "eliasalbouzidi/distilbert-nsfw-text-classifier"

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
            "text-classification",
            model=MODEL_ID,
            device=device,
            dtype=dtype,
            model_kwargs={"low_cpu_mem_usage": True},
        )
        # Avoid wasting cycles allocating large matmul workspaces for tiny models.
        if device != -1:
            torch.backends.cuda.matmul.allow_tf32 = True
        print(
            f"Model ready in {time.perf_counter() - t0:.2f}s on {_device_label}.",
            file=sys.stderr,
        )
    return _pipe


def classify(text: str) -> dict:
    """
    Classify a single string.

    Returns:
        {"label": "safe"|"nsfw", "score": float in [0, 1]}
    """
    text = (text or "").strip()
    if not text:
        raise ValueError("Input text is empty.")

    result = get_pipeline()(text)[0]
    return {"label": result["label"], "score": float(result["score"])}


def format_result(text: str, result: dict) -> str:
    label = result["label"]
    score = result["score"]
    preview = text if len(text) <= 80 else text[:77] + "..."
    return f'[{label.upper()}] score={score:.4f}  |  "{preview}"'


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Classify text as safe or nsfw (GPU when available).",
    )
    parser.add_argument(
        "text",
        nargs="*",
        help="Text to classify. If omitted, reads from stdin or prompts interactively.",
    )
    parser.add_argument(
        "-j",
        "--json",
        action="store_true",
        help="Print raw JSON result instead of a human-readable line.",
    )
    args = parser.parse_args(argv)

    if args.text:
        texts = [" ".join(args.text)]
    elif not sys.stdin.isatty():
        texts = [line.strip() for line in sys.stdin if line.strip()]
        if not texts:
            print("No input text received on stdin.", file=sys.stderr)
            return 1
    else:
        try:
            user = input("Enter text to classify: ").strip()
        except EOFError:
            print("No input.", file=sys.stderr)
            return 1
        if not user:
            print("Empty input.", file=sys.stderr)
            return 1
        texts = [user]

    # Load once before the loop (also warms CUDA kernels).
    get_pipeline()

    for text in texts:
        try:
            t0 = time.perf_counter()
            result = classify(text)
            infer_s = time.perf_counter() - t0
        except Exception as exc:
            print(f"Error classifying text: {exc}", file=sys.stderr)
            return 1

        if args.json:
            print(
                json.dumps(
                    {"text": text, "device": _device_label, **result},
                    ensure_ascii=False,
                )
            )
        else:
            print(format_result(text, result))
            print(f"(inference {infer_s * 1000:.1f} ms on {_device_label})", file=sys.stderr)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
