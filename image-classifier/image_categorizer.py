"""
Multi-class NSFW image categorizer using strangerguardhf/nsfw_image_detection.

Labels:
  - Anime Picture
  - Hentai
  - Normal
  - Pornography
  - Enticing or Sensual
"""

from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

import torch
from PIL import Image
from transformers import AutoImageProcessor, SiglipForImageClassification


MODEL_ID = "strangerguardhf/nsfw_image_detection"

ID2LABEL = {
    0: "Anime Picture",
    1: "Hentai",
    2: "Normal",
    3: "Pornography",
    4: "Enticing or Sensual",
}

_model = None
_processor = None
_device: torch.device | None = None
_device_label = "cpu"


def resolve_device() -> tuple[torch.device, torch.dtype, str]:
    """Prefer CUDA + float16 when available."""
    if torch.cuda.is_available():
        name = torch.cuda.get_device_name(0)
        return torch.device("cuda:0"), torch.float16, f"cuda:0 ({name})"
    return torch.device("cpu"), torch.float32, "cpu"


def get_model():
    """Lazy-load model + processor onto GPU/CPU once."""
    global _model, _processor, _device, _device_label
    if _model is None:
        _device, dtype, _device_label = resolve_device()
        print(f"Loading model: {MODEL_ID} on {_device_label} ...", file=sys.stderr)
        t0 = time.perf_counter()
        _processor = AutoImageProcessor.from_pretrained(MODEL_ID)
        _model = SiglipForImageClassification.from_pretrained(
            MODEL_ID,
            dtype=dtype,
            low_cpu_mem_usage=True,
        )
        _model.to(_device)
        _model.eval()
        if _device.type == "cuda":
            torch.backends.cuda.matmul.allow_tf32 = True
        print(
            f"Model ready in {time.perf_counter() - t0:.2f}s on {_device_label}.",
            file=sys.stderr,
        )
    return _model, _processor, _device


def classify(image_path: str | Path) -> dict:
    """
    Classify a single image file.

    Returns:
        {
            "label": str,           # top predicted class
            "score": float,         # top class probability
            "scores": {label: float, ...},  # all class probabilities
        }
    """
    path = Path(image_path)
    if not path.is_file():
        raise FileNotFoundError(f"Image not found: {path}")

    model, processor, device = get_model()

    with Image.open(path) as img:
        img = img.convert("RGB")
        inputs = processor(images=img, return_tensors="pt")
        inputs = {k: v.to(device) for k, v in inputs.items()}

    with torch.no_grad():
        outputs = model(**inputs)
        probs = torch.nn.functional.softmax(outputs.logits, dim=-1).squeeze(0)

    scores = {
        ID2LABEL[i]: float(probs[i].item()) for i in range(len(ID2LABEL))
    }
    top_idx = int(probs.argmax().item())
    return {
        "label": ID2LABEL[top_idx],
        "score": float(probs[top_idx].item()),
        "scores": scores,
    }


def format_result(image_path: str | Path, result: dict) -> str:
    lines = [f"[{result['label'].upper()}] score={result['score']:.4f}  |  {image_path}"]
    # Show all classes sorted by probability
    for label, score in sorted(result["scores"].items(), key=lambda x: -x[1]):
        lines.append(f"  {score:.4f}  {label}")
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Categorize an image (Normal / Pornography / Hentai / etc.).",
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
        help="Print raw JSON result instead of a human-readable block.",
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

    get_model()

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
