#!/usr/bin/env python3
"""Invoke the pinned, separately installed upstream baker; package its CC BY-SA data.

No upstream implementation is copied into the app. Native transport is encoded
sRGB -> normalized CMY optical density -> encoded sRGB, with native exposure
(no default SDR gain), local DIR on, spatial/random effects off. Generated
tables and their manifest remain CC BY-SA 4.0; the upstream GPL runtime stays
in the external research environment.
"""
import argparse
import dataclasses
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

COMMIT = "3bb2c2d2801ff68b92019cf1dbcbb133d60832bc"
NAME = "SpekPortraEndura"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--fixtures", type=Path)
    args = parser.parse_args()
    source = args.source.resolve()
    if subprocess.check_output(["git", "-C", str(source), "rev-parse", "HEAD"], text=True).strip() != COMMIT:
        raise ValueError("Unexpected upstream revision")
    if subprocess.check_output(["git", "-C", str(source), "status", "--porcelain", "--untracked-files=no"], text=True).strip():
        raise ValueError("Upstream tracked files must be clean")
    os.environ.setdefault("NUMBA_NUM_THREADS", "4")
    os.environ.setdefault("OPENBLAS_NUM_THREADS", "4")
    sys.path.insert(0, str(source / "src"))
    import numpy as np
    import colour
    from spektrafilm_lut_creator.bundles import BundleSpec
    from spektrafilm_lut_creator.builders import BundleBuilder
    from spektrafilm_lut_creator.color_spaces import get as get_color_space, decode_cctf, encode_cctf
    from bake_film_luts import sample

    spec = BundleSpec(film_profile="kodak_portra_400", print_profiles=("kodak_portra_endura",),
                      input_color_space="sRGB", output_color_space="sRGB", topology="2lut",
                      resolution=65, stops_above_midgray=None)
    builder = BundleBuilder(spec)
    bundle = builder.build()
    wire = bundle.meta.wires.cmy_film
    lo, hi = np.array(wire.d_min), np.array(wire.d_max)
    arrays = {m.role: lut.table for m, (_, lut) in zip(bundle.meta.luts, bundle.luts)}
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=True)
    tables = {}
    for role, key in [("film", "density"), ("print", "print")]:
        values = arrays[role]
        if not np.isfinite(values).all() or values.min() < 0 or values.max() > 1:
            raise ValueError("Invalid normalized table")
        rgba = np.concatenate([values, np.ones(values.shape[:-1] + (1,))], axis=-1)
        data = rgba.astype("<f4").tobytes()
        filename = f"{NAME}-{key}-v1.bin"
        (out / filename).write_bytes(data)
        tables[key] = dict(file=filename, dimension=65, sha256=hashlib.sha256(data).hexdigest())

    # Pinned private factory ensures the independent full reference uses exactly
    # the same runtime settings, but does not evaluate the baked tables.
    pipeline = builder._make_pipeline(spec, get_color_space("sRGB"), get_color_space("sRGB"), spec.print_profiles[0])
    anchors = np.concatenate([np.repeat(np.linspace(0, 1, 17)[:, None], 3, axis=1), np.array([
        [.78, .59, .48], [.55, .39, .30], [.14, .09, .06], [.3, .6, .95],
        [.15, .45, .18], [1, .05, .12], [.1, .9, 1], [.99, .98, .95]])])
    probes = np.concatenate([np.random.default_rng(20261101).random((8192, 3)),
                             np.repeat(np.linspace(0, 1, 4097)[:, None], 3, axis=1), anchors])
    lin = decode_cctf(probes.reshape(-1, 1, 3), "sRGB").astype(np.float32)
    reference = np.clip(encode_cctf(pipeline.process(lin), "sRGB"), 0, 1).reshape(-1, 3)
    ref_density = (np.asarray(pipeline.process(lin[-len(anchors):], collect="cmy_film")).reshape(-1, 3) - lo) / (hi - lo)
    evaluated = sample(arrays["print"], sample(arrays["film"], probes))
    lab = lambda x: colour.XYZ_to_Lab(colour.RGB_to_XYZ(x, "sRGB", apply_cctf_decoding=True))
    delta = colour.delta_E(lab(reference), lab(evaluated), method="CIE 2000")
    validation = dict(samples=len(probes), deltaE2000Median=float(np.median(delta)),
                      deltaE2000P95=float(np.percentile(delta, 95)), deltaE2000Max=float(delta.max()),
                      maximumRGBError=float(np.abs(reference-evaluated).max()))
    manifest = dict(version=2, identifier="spek-portra-endura-density-v1", tables=tables,
                    densityMinimum=lo.tolist(), densityMaximum=hi.tolist(),
                    contract=dict(input="developed_srgb", intermediate="cmy_optical_density", output="encoded_srgb"),
                    source="https://github.com/andreavolpato/spektrafilm", sourceCommit=COMMIT,
                    author="Andrea Volpato", license="CC-BY-SA-4.0", licenseFile="SPEKTRAFILM_LICENSE.txt",
                    modificationNotice="Repacked upstream 65-cube film/print LUTs as little-endian RGBA32F; native SDR exposure; see Spektrafilm-CHANGELOG.txt",
                    upstreamBundle=dataclasses.asdict(bundle.meta), validation=validation,
                    references=[dict(input=x.tolist(), density=d.tolist(), output=y.tolist()) for x, d, y in
                                zip(anchors, ref_density, reference[-len(anchors):])])
    (out / f"{NAME}-material-v1.json").write_text(json.dumps(manifest, indent=2) + "\n")
    shutil.copyfile(source / "SPEKTRAFILM_LICENSE.txt", out / "SPEKTRAFILM_LICENSE.txt")
    (out / "Spektrafilm-CHANGELOG.txt").write_text(
        f"2026-11-01: JustShoot material adaptation of Spektrafilm by Andrea Volpato.\n"
        f"Source: https://github.com/andreavolpato/spektrafilm/tree/{COMMIT}\n"
        "Profiles, generated density/print tables and manifest: CC BY-SA 4.0.\n"
        "Changes: 65-cube 2-LUT bake, sRGB input/output, native exposure gain 1;\n"
        "local DIR retained; spatial effects, random effects and sharpening disabled\n"
        "by upstream lut_mode; repacked to RGBA Float32, red fastest, alpha=1.\n"
        "No upstream Python implementation is shipped in the app.\n"
        "License: SPEKTRAFILM_LICENSE.txt (unaltered). No warranty or endorsement.\n")
    print(json.dumps(validation), flush=True)
    if validation["deltaE2000P95"] > .5:
        raise ValueError("Two-stage approximation exceeds the P95 accuracy target")
    if args.fixtures:
        from PIL import Image, ImageCms
        previews = out / "reference"
        previews.mkdir(exist_ok=True)
        icc = ImageCms.ImageCmsProfile(ImageCms.createProfile("sRGB")).tobytes()
        for path in sorted(args.fixtures.glob("*.png")):
            im = Image.open(path).convert("RGB")
            im.thumbnail((1536, 1536), Image.Resampling.LANCZOS)
            rgb = np.asarray(im, dtype=np.float32) / 255
            result = np.clip(encode_cctf(pipeline.process(decode_cctf(rgb, "sRGB").astype(np.float32)), "sRGB"), 0, 1)
            Image.fromarray(np.round(result * 255).astype("uint8")).save(previews / path.name, icc_profile=icc)
            print(f"reference_export scene={path.stem}", flush=True)


if __name__ == "__main__":
    main()
