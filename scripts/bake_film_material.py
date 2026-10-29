#!/usr/bin/env python3
"""Bake the pinned MIT model's actual layer densities and Endura print response.

Run in the LUT research environment with --source pointing to the pinned checkout.
The app consumes binary tables; no Python or spectral model runs on the phone.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

COMMIT = "bcbcfc6861f49cc706dc5d00ea048e4853060aab"
ROOT = Path(__file__).resolve().parent.parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--output", type=Path, default=ROOT / "JustShoot/Resources")
    args = parser.parse_args()
    source = args.source.resolve()
    assert subprocess.check_output(["git", "-C", str(source), "rev-parse", "HEAD"], text=True).strip() == COMMIT
    assert not subprocess.check_output(["git", "-C", str(source), "status", "--porcelain", "--untracked-files=no"], text=True).strip()
    os.environ.setdefault("MPLBACKEND", "Agg")
    os.environ.setdefault("NUMBA_NUM_THREADS", "4")
    sys.path.insert(0, str(source / "src"))
    import numpy as np
    import colour
    from spectral_film_lut.film_spectral import FilmSpectral
    from spectral_film_lut.negative_film.kodak_portra_400 import KODAK_PORTRA_400
    from spectral_film_lut.print_film.kodak_portra_endura import KODAK_PORTRA_ENDURA
    from spectral_film_lut.utils import film_conversion
    from bake_film_luts import sample

    film, paper = FilmSpectral(KODAK_PORTRA_400), FilmSpectral(KODAK_PORTRA_ENDURA)
    dimension = 65
    settings = dict(input_colorspace="sRGB", output_gamut="Rec. 709", gamma_func="sRGB",
                    exp_kelvin=6500, projector_kelvin=6500, color_masking=film.color_masking,
                    adx_coding=False, white_clip=True, white_balance=1,
                    upsampling_method="SFL upsampling")
    grid = colour.LUT3D(size=dimension).table
    maximum = np.asarray(film.d_max)
    density = film_conversion(grid.copy(), film, paper, mode="negative", **settings) / maximum
    printed = film_conversion((grid * maximum).copy(), film, paper, mode="print", **settings)
    args.output.mkdir(parents=True, exist_ok=True)
    tables = {}
    for name, values in [("density", density), ("print", printed)]:
        assert np.isfinite(values).all() and values.min() >= -1e-6 and values.max() <= 1.000001
        values = np.clip(values, 0, 1)
        # Runtime order is blue-major, red fastest, matching existing compiled cubes.
        rgba = np.concatenate([values.transpose(2, 1, 0, 3), np.ones((dimension,) * 3 + (1,))], axis=-1)
        data = rgba.astype("<f4").tobytes()
        filename = f"PortraEndura-{name}-v1.bin"
        (args.output / filename).write_bytes(data)
        tables[name] = dict(file=filename, dimension=dimension, sha256=hashlib.sha256(data).hexdigest())

    probes = np.concatenate([np.random.default_rng(20261029).random((4096, 3)),
                             np.repeat(np.linspace(0, 1, 2049)[:, None], 3, axis=1)])
    # sample() expects blue-major arrays; comparison is against full, unbaked model.
    encoded = sample(density.transpose(2, 1, 0, 3), probes)
    evaluated = sample(printed.transpose(2, 1, 0, 3), encoded)
    reference = film_conversion(probes.copy(), film, paper, mode="full", **settings)
    lab = lambda x: colour.XYZ_to_Lab(colour.RGB_to_XYZ(x, "sRGB", apply_cctf_decoding=True))
    de = colour.delta_E(lab(evaluated), lab(reference), method="CIE 2000")
    anchors = np.concatenate([probes[-2049::256], np.array([
        [.78, .59, .48], [.55, .39, .30], [.14, .09, .06], [.3, .6, .95],
        [.15, .45, .18], [1, .05, .12], [.1, .9, 1], [.99, .98, .95]])])
    anchor_density = film_conversion(anchors.copy(), film, paper, mode="negative", **settings) / maximum
    anchor_output = film_conversion(anchors.copy(), film, paper, mode="full", **settings)
    manifest = dict(version=1, identifier="portra-endura-density-v1", dimension=dimension,
                    input="encoded sRGB [0,1], display-referred approximation; not scene radiance",
                    intermediate="per-layer activation density above base; normalized by densityMaximum; NOT RGB or ADX",
                    densityMaximum=maximum.tolist(), source="https://github.com/JanLohse/spectral_film_lut",
                    sourceCommit=COMMIT, license="MIT", licenseFile="SpectralFilmLUT-LICENSE.txt",
                    settings=settings, tables=tables,
                    validation=dict(samples=len(probes), deltaE2000Median=float(np.median(de)),
                                    deltaE2000P95=float(np.percentile(de, 95)), deltaE2000Max=float(de.max())),
                    references=[dict(input=x.tolist(), density=d.tolist(), output=y.tolist()) for x, d, y in zip(
                        anchors, anchor_density, anchor_output)])
    (args.output / "PortraEndura-material-v1.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(json.dumps(manifest["validation"]))


if __name__ == "__main__":
    main()
