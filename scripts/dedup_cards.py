#!/usr/bin/env python3
"""Collapse within-INDEX multi-SUB duplicates in the card dataset.

A card ID has the form `{INDEX5}_{SUB3}` (e.g. `00538_000` / `00538_001`...).
We confirmed via analyze_card_dupes.py that within an INDEX every SUB shares
identical metadata (type/subtype/notes), so they are intentional multi-photo
captures of the same physical SKU. For the library we want one canonical
photo per SKU.

Strategy: per INDEX, keep the lowest SUB (typically `_000`). Drop the rest:
- remove from cards.json `cards` list
- delete the corresponding `.heic` from JustShoot/Resources/cards/

Cross-INDEX metadata twins (3 known cases) are NOT touched — they may be
distinct packaging editions sharing the same brand/product/iso, and their
visual hash differs enough (Hamming 12+) to suggest they're separate.

Run from project root:
    python3 scripts/dedup_cards.py [--dry-run]
"""
from __future__ import annotations

import argparse
import json
import sys
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
JSON_PATH = ROOT / "JustShoot" / "Resources" / "cards.json"
CARDS_DIR = ROOT / "JustShoot" / "Resources" / "cards"


def index_key(card_id: str) -> str:
    return card_id.split("_")[0]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true", help="Print what would change without modifying anything")
    args = ap.parse_args()

    bundle = json.loads(JSON_PATH.read_text(encoding="utf-8"))
    cards = bundle["cards"]
    before = len(cards)

    groups: dict[str, list[dict]] = defaultdict(list)
    for c in cards:
        groups[index_key(c["id"])].append(c)

    keep: list[dict] = []
    drop: list[dict] = []
    for idx, group in groups.items():
        # Sort by full ID lexicographically so SUB ordering is preserved.
        sorted_group = sorted(group, key=lambda c: c["id"])
        keep.append(sorted_group[0])
        drop.extend(sorted_group[1:])

    # Preserve original ordering of kept cards (sorted by id ascending)
    keep.sort(key=lambda c: c["id"])

    after = len(keep)
    dropped = len(drop)
    print(f"before: {before}, after: {after}, dropped: {dropped}")
    print(f"groups with extras collapsed: {sum(1 for v in groups.values() if len(v) > 1)}")

    if args.dry_run:
        print("\n(dry-run) sample drops:")
        for c in drop[:10]:
            print(f"  - {c['id']}  {c.get('brand')}/{c.get('product')}")
        return 0

    # 1) delete HEIC files for dropped cards
    missing = 0
    for c in drop:
        path = CARDS_DIR / c["image"]
        if path.exists():
            path.unlink()
        else:
            missing += 1
            print(f"  ? file already missing: {c['image']}", file=sys.stderr)

    # 2) update bundle and write JSON
    bundle["cards"] = keep
    bundle["count"] = after
    # Bump a dedup-version marker so consumers can tell this happened.
    bundle["dedup_version"] = 1

    JSON_PATH.write_text(
        json.dumps(bundle, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )

    print(f"\nremoved {dropped - missing} files, {missing} were already gone")
    print(f"wrote {JSON_PATH} ({JSON_PATH.stat().st_size} bytes)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
