#!/usr/bin/env python3
"""Bake the selected community film models.

Use the pinned Spectral Film LUT checkout and the research Python environment:
    python scripts/bake_film_luts.py --source /path/to/spectral_film_lut
Then run scripts/compile_luts.py. No model code runs in the app.
"""

from __future__ import annotations

import argparse
import hashlib
import importlib
import importlib.metadata
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
COMMIT = "bcbcfc6861f49cc706dc5d00ea048e4853060aab"
SOURCE = "https://github.com/JanLohse/spectral_film_lut"
# resource name, negative/slide module, constant, print module, constant
STOCKS = [
    ("FujiC200", "negative_film.fuji_c200", "FUJI_C200", "print_film.fuji_ca_pdII", "FUJI_CA_PRO_PDII"),
    ("FujiPro400H", "negative_film.fuji_pro_400h", "FUJI_PRO_400H", "print_film.fuji_ca_pdII", "FUJI_CA_PRO_PDII"),
    ("FujiProvia100F", "reversal_film.fuji_provia_100f", "FUJI_PROVIA_100F", None, None),
    ("KodakPortra400", "negative_film.kodak_portra_400", "KODAK_PORTRA_400", "print_film.kodak_portra_endura", "KODAK_PORTRA_ENDURA"),
]


def read_table(path: Path):
    import numpy as np
    from compile_luts import compile_cube

    compiled = compile_cube(path)
    magic, dimension, count = struct.unpack("<8sII", compiled[:16])
    if magic != b"JSLUT001" or count != dimension**3 * 4:
        raise ValueError(f"{path}: invalid compiled table")
    return np.frombuffer(compiled, dtype="<f4", offset=16).reshape(dimension, dimension, dimension, 4)[..., :3]


def sample(table, rgb):
    import numpy as np

    position = np.clip(rgb, 0, 1) * (len(table) - 1)
    lower = np.floor(position).astype(int)
    upper = np.minimum(lower + 1, len(table) - 1)
    fraction = position - lower
    result = np.zeros_like(position, dtype=np.float64)
    for b in (0, 1):
        for g in (0, 1):
            for r in (0, 1):
                flags = np.array([r, g, b])
                index = np.where(flags, upper, lower)
                weight = np.prod(np.where(flags, fraction, 1 - fraction), axis=-1)
                result += table[index[..., 2], index[..., 1], index[..., 0]] * weight[..., None]
    return result


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--output", type=Path, default=ROOT / "JustShoot/Resources")
    args = parser.parse_args()
    source = args.source.resolve()
    revision = subprocess.check_output(["git", "-C", str(source), "rev-parse", "HEAD"], text=True).strip()
    if revision != COMMIT:
        raise SystemExit(f"Expected {COMMIT}, got {revision}")
    if subprocess.check_output(["git", "-C", str(source), "status", "--porcelain", "--untracked-files=no"], text=True).strip():
        raise SystemExit("Source checkout has tracked modifications")
    os.environ.setdefault("MPLBACKEND", "Agg")
    os.environ.setdefault("NUMBA_NUM_THREADS", "4")
    sys.path.insert(0, str(source / "src"))

    import colour
    import numpy as np
    from spectral_film_lut.film_spectral import FilmSpectral
    from spectral_film_lut.utils import create_lut, film_conversion

    destination = args.output.resolve()
    destination.mkdir(parents=True, exist_ok=True)
    manifest = {
        "schemaVersion": 2,
        "revision": "community-srgb-20261024",
        "modelSource": SOURCE,
        "modelSourceCommit": COMMIT,
        "modelLicense": "MIT",
        "modelLicenseFile": "SpectralFilmLUT-LICENSE.txt",
        "input": "Encoded sRGB, unit domain",
        "output": "Encoded sRGB: Rec.709 primaries and sRGB transfer function, unit domain",
        "limitations": "Sources and rendering methods vary by stock. Not manufacturer endorsed or a measured iPhone/film match. sRGB decoding cannot undo the camera ISP or reconstruct scene radiance. Selection prioritizes appearance; no claim of universal best or community consensus.",
        "packages": {name: importlib.metadata.version(name) for name in ["numpy", "scipy", "colour-science", "numba", "matplotlib"]},
        "stocks": [],
    }
    reports = []
    gray = np.repeat(np.linspace(0, 1, 1025)[:, None], 3, axis=1)
    probes = np.concatenate([np.random.default_rng(20261024).random((2048, 3)), gray])
    anchors = np.array([[0, 0, 0], [1, 1, 1], [.5, .5, .5], [.5, .25, .75], [.75, .5, .25]])
    for name, film_module, film_constant, paper_module, paper_constant in STOCKS:
        print(f"Baking {name}", flush=True)
        film = FilmSpectral(getattr(importlib.import_module(f"spectral_film_lut.{film_module}"), film_constant))
        paper = None if paper_module is None else FilmSpectral(getattr(
            importlib.import_module(f"spectral_film_lut.{paper_module}"), paper_constant))
        settings = dict(mode="full", input_colorspace="sRGB", output_gamut="Rec. 709", gamma_func="sRGB",
                        exp_kelvin=6500, projector_kelvin=6500, tint=0.0, exp_comp=0.0,
                        color_masking=film.color_masking, red_light=0.0, green_light=0.0, blue_light=0.0,
                        sat_adjust=1.0, shadow_comp=0.0, push_pull=0.0, white_clip=True, white_balance=1,
                        inversion=False, idealized_curve=False, apd_intermediate=False,
                        upsampling_method="SFL upsampling")
        table = create_lut(film, paper, lut_size=33, cube=False, filter_mode=None, **settings)
        if not np.isfinite(table).all() or table.min() < 0 or table.max() > 1:
            raise ValueError(f"{name}: invalid output")
        path = destination / f"{name}.cube"
        comments = ["Community spectral model; not manufacturer endorsed or camera calibrated.",
                    "Derived from Spectral Film LUT by Jan Lohse, MIT License.",
                    f"Source: {SOURCE}/tree/{COMMIT}",
                    f"Film: {film.name}; print: {paper.name if paper else 'none (direct slide projection)' }.",
                    "Input: encoded sRGB [0,1]; output: encoded sRGB [0,1].",
                    "Recipe: LUTProvenance.json. No app shadow toe or legacy output calibration."]
        colour.io.write_LUT(colour.LUT3D(table=table, name=name, comments=comments), str(path), decimals=9)
        decoded = read_table(path)
        indices = np.round(anchors * 32).astype(int)
        np.testing.assert_allclose(sample(decoded, anchors), table[indices[:, 0], indices[:, 1], indices[:, 2]], atol=7e-8)
        reference = film_conversion(probes.copy(), film, paper, **settings)
        evaluated = sample(decoded, probes)
        to_lab = lambda rgb: colour.XYZ_to_Lab(colour.RGB_to_XYZ(rgb, "sRGB", apply_cctf_decoding=True))
        de = colour.delta_E(to_lab(reference), to_lab(evaluated), method="CIE 2000")
        # Anchors come directly from the unbaked model, independently of cube serialization.
        anchor_outputs = film_conversion(anchors.copy(), film, paper, **settings)
        stock = {"resourceName": name, "status": "communityModel", "source": SOURCE,
                 "film": film.name,
                 "print": paper.name if paper else None, "dimension": 33,
                 "sha256": hashlib.sha256(path.read_bytes()).hexdigest(), "settings": settings,
                 "modelFiles": {module: hashlib.sha256((source / "src/spectral_film_lut" /
                                  (module.replace(".", "/") + ".py")).read_bytes()).hexdigest()
                                for module in [film_module, paper_module] if module},
                 "referenceSamples": [{"input": x.tolist(), "output": y.tolist()} for x, y in zip(anchors, anchor_outputs)]}
        manifest["stocks"].append(stock)
        gray_steps = np.diff(sample(decoded, gray) @ np.array([.2126, .7152, .0722]))
        report = {"resourceName": name, "dimension": 33,
                  "fidelityAgainst": "Unbaked model on 2048 seeded random RGBs and 1025 gray inputs; not real film",
                  "deltaE2000Median": float(np.median(de)), "deltaE2000P95": float(np.percentile(de, 95)),
                  "deltaE2000Max": float(de.max()), "rgbRMSE": float(np.sqrt(np.mean((reference-evaluated)**2))),
                  "grayReversals": int(np.sum(gray_steps < -1e-5)),
                  "worstGrayStep": float(gray_steps.min())}
        reports.append(report)
        print(f"  33^3; model approximation dE00 p95={report['deltaE2000P95']:.3f}; worst gray step={report['worstGrayStep']:.7f}", flush=True)

    shutil.copyfile(source / "LICENSE", destination / manifest["modelLicenseFile"])
    (destination / "LUTProvenance.json").write_text(json.dumps(manifest, indent=2) + "\n")
    (destination / "LUTValidation.json").write_text(json.dumps(reports, indent=2) + "\n")


if __name__ == "__main__":
    main()
