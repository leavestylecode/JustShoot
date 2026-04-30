#!/usr/bin/env python3
"""Compute a coarse background-color label for each card image and inject it into cards.json.

Algorithm: downsample HEIC -> 48x48 RGB -> classify each pixel into one of 10 buckets
(red/orange/yellow/green/blue/purple/brown/black/white/gray). Each pixel votes UNWEIGHTED
so the dominant area (i.e. the box background) wins over small foreground logos and
text. The bucket with the highest pixel count wins.

Run from project root:
    python3 scripts/compute_card_colors.py
"""
from __future__ import annotations

import colorsys
import json
import sys
import time
from pathlib import Path

from PIL import Image
import pillow_heif

pillow_heif.register_heif_opener()

ROOT = Path(__file__).resolve().parent.parent
JSON_PATH = ROOT / "JustShoot" / "Resources" / "cards.json"
CARDS_DIR = ROOT / "JustShoot" / "Resources" / "cards"
SAMPLE_SIZE = 48


def classify_pixel(r: int, g: int, b: int) -> str:
    h, s, v = colorsys.rgb_to_hsv(r / 255.0, g / 255.0, b / 255.0)
    h_deg = h * 360.0

    # Pure black / white / gray buckets
    if v < 0.16:
        return "black"
    if s < 0.12:
        if v > 0.88:
            return "white"
        # Brown lives in the low-saturation warm range with mid brightness
        return "gray"

    # Brown: warm hue + mid-low brightness (boxes with cardboard / sepia look)
    if v < 0.5 and 8.0 <= h_deg <= 45.0:
        return "brown"

    # Hue bins for chromatic pixels
    if h_deg < 12.0 or h_deg >= 340.0:
        return "red"
    if h_deg < 38.0:
        return "orange"
    if h_deg < 65.0:
        return "yellow"
    if h_deg < 165.0:
        return "green"
    if h_deg < 255.0:
        return "blue"
    return "purple"  # 255-340


def dominant_color(image_path: Path) -> str | None:
    try:
        img = Image.open(image_path)
        img = img.convert("RGB").resize((SAMPLE_SIZE, SAMPLE_SIZE), Image.Resampling.BILINEAR)
    except Exception as exc:
        print(f"  ! failed to read {image_path.name}: {exc}", file=sys.stderr)
        return None

    counts: dict[str, int] = {}
    for r, g, b in img.getdata():
        bucket = classify_pixel(r, g, b)
        counts[bucket] = counts.get(bucket, 0) + 1

    if not counts:
        return None
    return max(counts.items(), key=lambda kv: kv[1])[0]


def main() -> int:
    if not JSON_PATH.exists():
        print(f"missing {JSON_PATH}", file=sys.stderr)
        return 1
    if not CARDS_DIR.exists():
        print(f"missing {CARDS_DIR}", file=sys.stderr)
        return 1

    with JSON_PATH.open("r", encoding="utf-8") as f:
        bundle = json.load(f)

    cards = bundle["cards"]
    total = len(cards)
    print(f"processing {total} cards from {CARDS_DIR}")

    start = time.time()
    counts: dict[str, int] = {}
    for i, card in enumerate(cards, start=1):
        image_name = card.get("image")
        if not image_name:
            card["color"] = None
            continue
        path = CARDS_DIR / image_name
        if not path.exists():
            print(f"  ? missing {image_name}", file=sys.stderr)
            card["color"] = None
            continue
        color = dominant_color(path)
        card["color"] = color
        counts[color or "null"] = counts.get(color or "null", 0) + 1
        if i % 50 == 0 or i == total:
            elapsed = time.time() - start
            print(f"  [{i}/{total}] {elapsed:.1f}s  latest={image_name} -> {color}")

    # Bump version metadata so consumers can detect the schema additions.
    bundle["color_version"] = 1

    with JSON_PATH.open("w", encoding="utf-8") as f:
        json.dump(bundle, f, ensure_ascii=False, indent=2)

    print("\ndistribution:")
    for color, n in sorted(counts.items(), key=lambda kv: -kv[1]):
        print(f"  {color:>8s}: {n}")
    print(f"wrote {JSON_PATH} ({JSON_PATH.stat().st_size} bytes)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
