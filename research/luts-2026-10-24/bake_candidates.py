#!/usr/bin/env python3
"""Bake a pinned, MIT-licensed spectral model into sRGB research LUTs.

Usage: python bake_candidates.py --source /path/to/spectral_film_lut
Install requirements.txt in an isolated Python 3.12 environment first.
This does not install the source project or import its GUI.
"""

from __future__ import annotations

import argparse
import hashlib
import importlib.metadata
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

HERE = Path(__file__).resolve().parent
SOURCE_URL = "https://github.com/JanLohse/spectral_film_lut"
SOURCE_COMMIT = "bcbcfc6861f49cc706dc5d00ea048e4853060aab"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, required=True)
    args = parser.parse_args()
    source = args.source.resolve()
    commit = subprocess.check_output(["git", "-C", str(source), "rev-parse", "HEAD"], text=True).strip()
    if commit != SOURCE_COMMIT:
        raise SystemExit(f"Expected source commit {SOURCE_COMMIT}; got {commit}")
    if subprocess.check_output(["git", "-C", str(source), "status", "--porcelain", "--untracked-files=no"], text=True).strip():
        raise SystemExit("Source has tracked modifications; use a clean checkout.")
    os.environ.setdefault("MPLBACKEND", "Agg")
    os.environ.setdefault("NUMBA_NUM_THREADS", "4")
    sys.path.insert(0, str(source / "src"))

    import colour
    import numpy as np
    from spectral_film_lut.film_spectral import FilmSpectral
    from spectral_film_lut.negative_film.kodak_portra_400 import KODAK_PORTRA_400
    from spectral_film_lut.print_film.kodak_portra_endura import KODAK_PORTRA_ENDURA
    from spectral_film_lut.print_film.kodak_endura_premier import KODAK_ENDURA_PREMIER
    from spectral_film_lut.utils import create_lut, film_conversion
    from audit_luts import read_cube, sample

    destination = HERE / "candidates"
    destination.mkdir(exist_ok=True)
    shutil.copyfile(source / "LICENSE", destination / "SpectralFilmLUT-LICENSE.txt")
    negative = FilmSpectral(KODAK_PORTRA_400)
    kwargs = dict(mode="full", input_colorspace="sRGB", output_gamut="Rec. 709",
                  gamma_func="sRGB", exp_kelvin=6500, projector_kelvin=6500,
                  tint=0.0, exp_comp=0.0, color_masking=negative.color_masking,
                  red_light=0.0, green_light=0.0, blue_light=0.0,
                  sat_adjust=1.0, shadow_comp=0.0, push_pull=0.0,
                  white_clip=True, white_balance=1, inversion=False,
                  idealized_curve=False, apd_intermediate=False,
                  upsampling_method="SFL upsampling")
    manifest = {"status": "Research candidates, not a measured match to real Portra or an iPhone camera profile.",
                "source": SOURCE_URL, "commit": SOURCE_COMMIT, "source_license": "MIT",
                "input": "Encoded sRGB, unit domain; inverse sRGB transfer applied inside model.",
                "output": "Encoded sRGB (Rec.709 primaries + sRGB transfer), unit domain.",
                "limitation": "Decoding display sRGB does not undo Apple's scene tone mapping or reconstruct scene radiance.",
                "settings": kwargs,
                "packages": {name: importlib.metadata.version(name) for name in
                             ["numpy", "scipy", "colour-science", "matplotlib", "numba"]},
                "luts": []}
    # Include arbitrary colors, a fine gray ramp and exact endpoints in fidelity probes.
    gray = np.repeat(np.linspace(0, 1, 1025)[:, None], 3, axis=1)
    probes = np.concatenate([np.random.default_rng(20261024).random((2048, 3)), gray])
    for paper_name, data, sizes in [
        ("PortraEndura", KODAK_PORTRA_ENDURA, [33, 65]),
        ("EnduraPremier", KODAK_ENDURA_PREMIER, [33]),
    ]:
        print(f"Preparing {paper_name}", flush=True)
        paper = FilmSpectral(data)
        reference = film_conversion(probes.copy(), negative, paper, **kwargs)
        for size in sizes:
            name = f"Portra400_{paper_name}_sRGB_{size}"
            print(f"Baking {name}", flush=True)
            table = create_lut(negative, paper, lut_size=size, cube=False, filter_mode=None, **kwargs)
            if not np.isfinite(table).all() or table.min() < 0 or table.max() > 1:
                raise RuntimeError(f"{name}: invalid or out-of-domain output")
            target = destination / f"{name}.cube"
            comments = [
                "Research candidate; not Kodak endorsed; not camera calibrated.",
                "Derived from Spectral Film LUT by Jan Lohse, MIT License.",
                f"Source: {SOURCE_URL}/tree/{SOURCE_COMMIT}",
                "Baked by JustShoot research script; see manifest.json for settings.",
                "Input: encoded sRGB [0,1]. Output: encoded sRGB [0,1].",
                "No spatial grain, halation, bloom, app shadow toe or app calibration.",
            ]
            colour.io.write_LUT(colour.LUT3D(table=table, name=name, comments=comments), str(target), decimals=9)
            decoded, _ = read_cube(target)
            # Check file ordering and serialization using grid points independent of its writer.
            grid_probes = np.array([[0, 0, 0], [1, 0, 0], [0, 1, 0], [0, 0, 1], [1, 1, 1], [0.5, 0.25, 0.75]])
            indices = np.round(grid_probes * (size - 1)).astype(int)
            np.testing.assert_allclose(sample(decoded, grid_probes),
                                       table[indices[:, 0], indices[:, 1], indices[:, 2]], atol=2e-8)
            evaluated = sample(decoded, probes)
            error = evaluated - reference
            reference_lab = colour.XYZ_to_Lab(colour.RGB_to_XYZ(reference, "sRGB", apply_cctf_decoding=True))
            evaluated_lab = colour.XYZ_to_Lab(colour.RGB_to_XYZ(evaluated, "sRGB", apply_cctf_decoding=True))
            delta_e = colour.delta_E(reference_lab, evaluated_lab, method="CIE 2000")
            manifest["luts"].append({"file": target.name, "paper": paper.name, "dimension": size,
                                     "sha256": hashlib.sha256(target.read_bytes()).hexdigest(),
                                     "rgba_float32_bytes": size**3 * 16,
                                     "fidelity_against": "Unbaked model at 2048 seeded random RGBs + 1025 gray samples; not real film.",
                                     "rgb_rmse": float(np.sqrt(np.mean(error**2))),
                                     "rgb_max_absolute_error": float(np.max(abs(error))),
                                     "deltaE2000_median": float(np.median(delta_e)),
                                     "deltaE2000_p95": float(np.percentile(delta_e, 95)),
                                     "deltaE2000_max": float(np.max(delta_e))})
    (destination / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print("Baked and checked 3 research LUTs.", flush=True)


if __name__ == "__main__":
    main()
