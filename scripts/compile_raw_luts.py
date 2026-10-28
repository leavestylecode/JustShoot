#!/usr/bin/env python3
"""Compile the verified CLFs to legacy scene-linear tables and canonical sRGB look cubes.

Runtime binary: JSRAW001, UInt32 grid=65, UInt32 halfTableLength=65536,
then little-endian Float32 input half-domain, red-fast RGBA cube, output half-domain.
No legacy source nodes are resampled. The 65³ display cube accepts rendered sRGB.
All new captures (plan v2 / RAW recipe v4), preview and Live Photo use that same
display interpretation after complete color-managed source development. The exact
scene-linear tables remain solely for recovery of older checkpointed jobs.
"""
from pathlib import Path
import hashlib
import json
import struct
import xml.etree.ElementTree as ET

import numpy as np
import PyOpenColorIO as ocio

from bake_fujifilm_raw_luts import MODES

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "research/luts-2026-10-24/derived/apple-raw-fujifilm"
DEST = ROOT / "JustShoot/Resources"
MATRIX = np.array([[.627403895934699, .329283038377883, .043313065687418],
                   [.069097289358232, .919540395075459, .011362315566309],
                   [.016391438875150, .088013307877226, .895595253247624]])


def sha(data):
    return hashlib.sha256(data).hexdigest()


def main():
    source = json.loads((SOURCE / "manifest.json").read_text())
    manifest = {"schemaVersion": 1, "source": source["source"],
                "input": source["input"], "rawDevelopmentContract": source["rawDevelopmentContract"],
                "outputViewingAssumption": source["outputViewingAssumption"],
                "runtimeUsage": {'capturePlanVersion': 2, 'rawRecipeVersion': 4, 'canonicalCube': 'The previously named sRGB preview cube is the canonical display-referred look for all new RAW stills, HEIF, Live Photo and viewfinder frames. It accepts and returns encoded sRGB. The transform is a display interpretation derived from the official LUT, not a calibrated reproduction of a Fujifilm camera sensor.', 'legacyTables': 'JSRAW001 scene-linear tables remain for recovery of already checkpointed version 1/3 RAW jobs and regression verification. New camera captures do not load these tables.'}, "stocks": []}
    grid = np.linspace(0, 1, 65, dtype=np.float32)
    b, g, r = np.meshgrid(grid, grid, grid, indexing="ij")
    encoded = np.stack([r, g, b], axis=-1).reshape(-1, 3)
    linear = np.where(encoded <= .04045, encoded / 12.92, ((encoded + .055) / 1.055) ** 2.4)
    preview_input = np.ascontiguousarray(linear @ MATRIX.T, dtype=np.float32)
    rng = np.random.default_rng(20261024)
    probes = np.concatenate([np.repeat(np.array([-.02, -.005, 0, 1e-7, .001, .01, .18, 1, 4, 16, 64], dtype=np.float32)[:, None], 3, axis=1),
                             rng.uniform(-.01, 8, (192, 3)).astype(np.float32)])
    for stock in source["stocks"]:
        if stock["mode"] not in MODES:
            continue
        path = SOURCE / stock["file"]
        assert sha(path.read_bytes()) == stock["sha256"]
        xml = ET.parse(path).getroot()
        nodes = [n for n in xml if n.tag.startswith("LUT")]
        assert [n.tag for n in nodes] == ["LUT1D", "LUT3D", "LUT1D"]
        arrays = [np.fromstring(n.find("Array").text, sep=" ", dtype=np.float32) for n in nodes]
        # CLF arrays are blue-fast; runtime cubes and the existing app are red-fast.
        first = arrays[0].reshape(65536, -1)[:, 0]
        cube = arrays[1].reshape(65, 65, 65, 3).transpose(2, 1, 0, 3)
        last = arrays[2].reshape(65536, -1)[:, 0]
        rgba = np.concatenate([cube, np.ones((65, 65, 65, 1), dtype=np.float32)], axis=-1)
        assert np.isfinite(first).all() and np.isfinite(last).all() and np.isfinite(rgba).all()
        name = "FujiRaw" + stock["mode"].replace("-", "").replace(".", "")
        binary = struct.pack("<8sII", b"JSRAW001", 65, 65536) + first.astype("<f4").tobytes() + rgba.astype("<f4").tobytes() + last.astype("<f4").tobytes()
        (DEST / f"{name}.jsraw").write_bytes(binary)
        cpu = ocio.Config.CreateRaw().getProcessor(ocio.FileTransform(src=str(path), interpolation=ocio.INTERP_LINEAR)).getDefaultCPUProcessor()
        preview = preview_input.copy()
        cpu.applyRGB(preview)
        preview_rgba = np.column_stack([preview, np.ones(len(preview), dtype=np.float32)])
        compiled = struct.pack("<8sII", b"JSLUT001", 65, preview_rgba.size) + preview_rgba.astype("<f4").tobytes()
        (DEST / f"{name}.jslut").write_bytes(compiled)
        expected = probes.copy()
        cpu.applyRGB(expected)
        manifest["stocks"].append({"mode": stock["mode"], "resourceName": name,
            "clfSHA256": stock["sha256"], "binarySHA256": sha(binary), "previewSHA256": sha(compiled),
            "referenceSamples": [{"input": a.tolist(), "output": b.tolist()} for a, b in zip(probes, expected)]})
        print(name, len(binary), flush=True)
    (DEST / "RawLUTProvenance.json").write_text(json.dumps(manifest, indent=2) + "\n")


if __name__ == "__main__":
    main()
