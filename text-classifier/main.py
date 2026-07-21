"""
NSFW text classifier using eliasalbouzidi/distilbert-nsfw-text-classifier.

Labels: "safe" | "nsfw"
"""

from __future__ import annotations

import argparse
import sys

from transformers import pipeline


MODEL_ID = "eliasalbouzidi/distilbert-nsfw-text-classifier"

# Lazy-loaded so import-only usage stays cheap until first classify() call.
_pipe = None


def get_pipeline():
    global _pipe
    if _pipe is None:
        print(f"Loading model: {MODEL_ID} ...", file=sys.stderr)
        _pipe = pipeline("text-classification", model=MODEL_ID)
        print("Model ready.", file=sys.stderr)
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
        description="Classify text as safe or nsfw.",
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
        # Piped / redirected stdin
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

    import json

    for text in texts:
        try:
            result = classify(text)
        except Exception as exc:
            print(f"Error classifying text: {exc}", file=sys.stderr)
            return 1

        if args.json:
            print(json.dumps({"text": text, **result}, ensure_ascii=False))
        else:
            print(format_result(text, result))

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
