#!/usr/bin/env python3
"""Convert three CC BY-SA 4.0 RawTherapee Hald CLUTs to bounded sRGB cubes.

Extract the named PNGs and README.txt from https://rawtherapee.com/shared/HaldCLUT.zip
(collection 2015-09-20), then pass that directory with --source. The generated
LUTs and their binary representations retain CC BY-SA 4.0. No source runs in iOS.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

import numpy as np
from PIL import Image

from bake_film_luts import ADAPTED_BY, CUBE_CREDIT, read_table, sample

ROOT = Path(__file__).resolve().parents[1]
SOURCE = "https://rawtherapee.com/shared/HaldCLUT.zip"
STOCKS = [
    ("IlfordHP5Plus400", "Ilford HP5 Plus 400.png", "3f803b34a7db73583cf8fbbfc46f1711869d80e415ceaefa5b42e6ea29b0b4f6"),
    ("KodakTMax100", "Kodak T-Max 100.png", "cf40a917dd5760f8645edee9d898d715e9549c5ddbeddbbeb1dd0660dde5ffbf"),
    ("KodakTriX400", "Kodak TRI-X 400 2.png", "fbbb7498a9aafd7df8c8d0e347a5850e76fb30b3ab4a25fc4d340c0591e4d325"),
]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--output", type=Path, default=ROOT / "JustShoot/Resources")
    args = parser.parse_args()
    destination = args.output
    destination.mkdir(parents=True, exist_ok=True)
    readme = (args.source / "README.txt").read_text()
    if "CC BY-SA 4.0" not in readme or "2015-09-20" not in readme:
        raise ValueError("Unexpected source collection/license")
    manifest = {"schemaVersion": 1, "adaptedBy": ADAPTED_BY, "source": SOURCE, "collection": "2015-09-20",
                "license": "CC-BY-SA-4.0",
                "input": "Encoded sRGB [0,1]", "output": "Encoded sRGB [0,1]",
                "limitations": "Community appearance simulations, not measured iPhone/film matches or manufacturer endorsed.",
                "stocks": []}
    b, g, r = np.indices((33, 33, 33))
    grid = np.stack([r, g, b], axis=-1) / 32
    anchors = np.array([[0, 0, 0], [1, 1, 1], [.5, .5, .5], [.5, .25, .75], [.75, .5, .25]])
    probes = np.random.default_rng(20261103).random((4096, 3))
    for resource, filename, expected_hash in STOCKS:
        source = args.source / filename
        source_hash = hashlib.sha256(source.read_bytes()).hexdigest()
        if source_hash != expected_hash:
            raise ValueError(f"Unexpected source revision: {filename}")
        with Image.open(source) as image:
            pixels = np.asarray(image.convert("RGB"), dtype=np.float64) / 255
        dimension = round(pixels.shape[0] ** (2 / 3))
        if pixels.shape[0] != pixels.shape[1] or dimension ** 3 != pixels.shape[0] ** 2:
            raise ValueError(f"Not a square Hald CLUT: {filename}")
        original = pixels.reshape(dimension, dimension, dimension, 3)
        if not np.array_equal(original[..., 0], original[..., 1]) or not np.array_equal(original[..., 1], original[..., 2]):
            raise ValueError(f"Expected neutral monochrome LUT: {filename}")
        table = sample(original, grid)
        path = destination / (resource + ".cube")
        with path.open("w") as stream:
            stream.write(f'TITLE "{resource}"\n# {CUBE_CREDIT}\nLUT_3D_SIZE 33\n')
            for red, green, blue in table.reshape(-1, 3):
                stream.write(f"{red:.9f} {green:.9f} {blue:.9f}\n")
        decoded = read_table(path)
        reference = sample(original, anchors)
        np.testing.assert_allclose(sample(decoded, anchors), reference, atol=7e-8)
        difference = abs(sample(decoded, probes) - sample(original, probes))
        if not np.isfinite(decoded).all() or decoded.min() < 0 or decoded.max() > 1 or difference.max() > .025:
            raise ValueError(f"Invalid or inaccurate conversion: {filename}")
        manifest["stocks"].append({
            "resourceName": resource, "status": "communityHaldCLUT", "dimension": 33,
            "sourceFile": filename, "sourceDimension": dimension,
            "sourceSHA256": source_hash,
            "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
            "conversionMaxRGBError": float(difference.max()),
            "referenceSamples": [{"input": x.tolist(), "output": y.tolist()} for x, y in zip(anchors, reference)]})
        print(f"{resource}: {dimension} -> 33; maximum sampled RGB error {difference.max():.6f}")
    (destination / "RawTherapeeLUTProvenance.json").write_text(json.dumps(manifest, indent=2) + "\n")


if __name__ == "__main__":
    main()
