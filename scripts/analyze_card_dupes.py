#!/usr/bin/env python3
"""Analyze potential duplicates in the film card dataset.

Three notions of "duplicate" we surface separately:

1. **Same INDEX, multiple SUB** — IDs like `00181_000`, `00181_001` share the
   first 5 digits. By the source schema these are different photos of the
   same product (different boxes / angles / states). Aggregate stats only.

2. **Metadata twins** — distinct IDs but identical brand+product+format+iso+
   process+expiry+subtype+quantity. Likely the same SKU re-listed; trimming
   these is the clearest win.

3. **Visual near-duplicates** — perceptually similar images (dHash within a
   small Hamming distance). Catches the same photo cropped/recompressed.

Run from project root:
    python3 scripts/analyze_card_dupes.py
"""
from __future__ import annotations

import json
from collections import Counter, defaultdict
from pathlib import Path

from PIL import Image
import pillow_heif

pillow_heif.register_heif_opener()

ROOT = Path(__file__).resolve().parent.parent
JSON_PATH = ROOT / "JustShoot" / "Resources" / "cards.json"
CARDS_DIR = ROOT / "JustShoot" / "Resources" / "cards"


def index_key(card_id: str) -> str:
    return card_id.split("_")[0]


def metadata_key(card: dict) -> tuple:
    """Fields that, when all equal, mean two cards describe the same SKU."""
    return (
        (card.get("brand") or "").lower(),
        (card.get("product") or "").lower(),
        (card.get("format") or "").lower(),
        card.get("iso"),
        (card.get("process") or "").lower(),
        (card.get("expiry") or "").lower(),
        (card.get("subtype") or "").lower(),
        (card.get("quantity") or "").lower(),
    )


def dhash(image_path: Path, hash_size: int = 8) -> int | None:
    """8x8 difference hash → 64-bit int. Cheap and robust for near-dup detection."""
    try:
        img = Image.open(image_path).convert("L").resize(
            (hash_size + 1, hash_size), Image.Resampling.BILINEAR
        )
    except Exception:
        return None
    pixels = list(img.getdata())
    bits = 0
    for row in range(hash_size):
        for col in range(hash_size):
            left = pixels[row * (hash_size + 1) + col]
            right = pixels[row * (hash_size + 1) + col + 1]
            bits = (bits << 1) | (1 if left > right else 0)
    return bits


def hamming(a: int, b: int) -> int:
    return (a ^ b).bit_count()


def main() -> int:
    bundle = json.loads(JSON_PATH.read_text(encoding="utf-8"))
    cards = bundle["cards"]
    total = len(cards)
    print(f"total cards: {total}\n")

    # 1. INDEX-based stats ------------------------------------------------
    index_groups: dict[str, list[dict]] = defaultdict(list)
    for c in cards:
        index_groups[index_key(c["id"])].append(c)

    multi = {k: v for k, v in index_groups.items() if len(v) > 1}
    multi_card_count = sum(len(v) for v in multi.values())
    print(f"[1] INDEX with multiple SUB images: {len(multi)} groups, {multi_card_count} cards")
    sub_size_dist = Counter(len(v) for v in multi.values())
    for n, cnt in sorted(sub_size_dist.items()):
        print(f"    {n} sub-images × {cnt} groups = {n * cnt} cards")
    print(f"    extras beyond first SUB: {multi_card_count - len(multi)}")
    print()

    # 2. Metadata twins ---------------------------------------------------
    meta_groups: dict[tuple, list[dict]] = defaultdict(list)
    for c in cards:
        meta_groups[metadata_key(c)].append(c)
    meta_dupes = {k: v for k, v in meta_groups.items() if len(v) > 1}
    meta_redundant = sum(len(v) - 1 for v in meta_dupes.values())
    print(f"[2] Metadata-identical groups: {len(meta_dupes)}, redundant cards (would drop): {meta_redundant}")
    if meta_dupes:
        print("    sample groups:")
        for key, group in list(meta_dupes.items())[:8]:
            ids = ", ".join(c["id"] for c in group)
            label = f"{key[0]} / {key[1]} / {key[2]} / iso={key[3]}"
            print(f"      [{len(group)}] {label}  ids: {ids}")
    print()

    # 3. Visual near-duplicates ------------------------------------------
    print("[3] Computing dHash on all images (this takes a few seconds)...")
    hashes: list[tuple[str, int]] = []
    missing_hash = 0
    for c in cards:
        path = CARDS_DIR / c["image"]
        h = dhash(path)
        if h is None:
            missing_hash += 1
            continue
        hashes.append((c["id"], h))
    print(f"    hashed: {len(hashes)},  failed: {missing_hash}")

    # Exact dHash collisions = near-identical images
    by_hash: dict[int, list[str]] = defaultdict(list)
    for cid, h in hashes:
        by_hash[h].append(cid)
    exact = {h: ids for h, ids in by_hash.items() if len(ids) > 1}
    exact_redundant = sum(len(ids) - 1 for ids in exact.values())
    print(f"    exact dHash collisions: {len(exact)} groups, redundant: {exact_redundant}")

    # Near collisions — Hamming <= 4 (very tight; tune if needed)
    # Compare in O(n^2 / 2). 629^2 / 2 ≈ 200k. Fine.
    near_groups_seen: dict[str, set[str]] = {}
    for i in range(len(hashes)):
        ai, ah = hashes[i]
        if ai in near_groups_seen:
            continue
        for j in range(i + 1, len(hashes)):
            bi, bh = hashes[j]
            if hamming(ah, bh) <= 4:
                near_groups_seen.setdefault(ai, set()).add(bi)
    near_pairs = sum(len(v) for v in near_groups_seen.values())
    print(f"    near-duplicate pairs (Hamming<=4): {near_pairs}")
    if near_groups_seen:
        print("    sample near-dups:")
        for anchor, others in list(near_groups_seen.items())[:8]:
            print(f"      {anchor} ↔ {', '.join(sorted(others))}")
    print()

    # Cross-reference: which redundant metadata twins are also visual dupes?
    meta_twin_ids: set[str] = set()
    for group in meta_dupes.values():
        for c in group[1:]:
            meta_twin_ids.add(c["id"])
    visual_redundant_ids: set[str] = set()
    for ids in exact.values():
        for cid in ids[1:]:
            visual_redundant_ids.add(cid)
    overlap = meta_twin_ids & visual_redundant_ids
    print(f"[X] Cards flagged by BOTH metadata twin AND exact visual hash: {len(overlap)}")
    print(f"    Cards flagged ONLY by metadata twin: {len(meta_twin_ids - visual_redundant_ids)}")
    print(f"    Cards flagged ONLY by exact visual hash: {len(visual_redundant_ids - meta_twin_ids)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
