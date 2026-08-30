#!/usr/bin/env python3
"""Compile bundled .cube LUTs into JustShoot's direct-load binary format.

Run from the repository root:
    python3 scripts/compile_luts.py
    python3 scripts/compile_luts.py --check

Format (little-endian):
    8 bytes  magic "JSLUT001"
    uint32   cube dimension
    uint32   RGBA float count
    float32  RGBA entries, alpha fixed to 1.0
"""

from __future__ import annotations

import argparse
import struct
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
RESOURCE_DIR = ROOT / "JustShoot" / "Resources"
MAGIC = b"JSLUT001"
HEADER = struct.Struct("<8sII")


def compile_cube(path: Path) -> bytes:
    dimension = 0
    rgb: list[float] = []

    source_data = path.read_bytes()
    try:
        source_text = source_data.decode("utf-8")
    except UnicodeDecodeError:
        # Match FilmProcessor.readCubeText: sample rows are ASCII; only titles
        # occasionally contain legacy bytes.
        source_text = source_data.decode("iso-8859-1")

    for raw_line in source_text.splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue

        parts = line.split()
        if parts[0].upper() == "LUT_3D_SIZE":
            if len(parts) != 2:
                raise ValueError(f"{path.name}: malformed LUT_3D_SIZE")
            dimension = int(parts[1])
            continue

        if len(parts) != 3:
            continue
        try:
            rgb.extend(float(value) for value in parts)
        except ValueError:
            # TITLE / DOMAIN_* and other textual directives are not samples.
            continue

    expected_rgb_count = dimension**3 * 3
    if dimension <= 0 or len(rgb) != expected_rgb_count:
        raise ValueError(
            f"{path.name}: expected {expected_rgb_count} RGB floats, found {len(rgb)}"
        )

    rgba: list[float] = []
    rgba_extend = rgba.extend
    for index in range(0, len(rgb), 3):
        rgba_extend((rgb[index], rgb[index + 1], rgb[index + 2], 1.0))

    payload = struct.pack(f"<{len(rgba)}f", *rgba)
    return HEADER.pack(MAGIC, dimension, len(rgba)) + payload


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--check",
        action="store_true",
        help="verify committed .jslut files without rewriting them",
    )
    args = parser.parse_args()

    failures = 0
    for source in sorted(RESOURCE_DIR.glob("*.cube")):
        destination = source.with_suffix(".jslut")
        compiled = compile_cube(source)

        if args.check:
            if not destination.exists() or destination.read_bytes() != compiled:
                print(f"OUTDATED {destination.relative_to(ROOT)}")
                failures += 1
            else:
                print(f"OK       {destination.relative_to(ROOT)}")
            continue

        temporary = destination.with_suffix(".jslut.tmp")
        temporary.write_bytes(compiled)
        temporary.replace(destination)
        print(
            f"WROTE    {destination.relative_to(ROOT)} "
            f"({len(compiled):,} bytes)"
        )

    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
