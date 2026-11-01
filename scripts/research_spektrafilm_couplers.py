#!/usr/bin/env python3
"""Isolate upstream DIR chemistry; research outputs only, no application assets.

Run with the separately installed Spektrafilm research environment. The upstream
runtime is GPLv3; its profiles are CC BY-SA 4.0. This script invokes that runtime
without copying its implementation into JustShoot. Output photos are not LUTs.
"""
import argparse
import copy
import dataclasses
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

os.environ.setdefault("NUMBA_NUM_THREADS", "4")
os.environ.setdefault("OPENBLAS_NUM_THREADS", "4")

COMMIT = "3bb2c2d2801ff68b92019cf1dbcbb133d60832bc"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--research-root", type=Path, required=True)
    args = parser.parse_args()
    source, root = args.source.resolve(), args.research_root.resolve()
    actual = subprocess.check_output(["git", "-C", str(source), "rev-parse", "HEAD"], text=True).strip()
    if actual != COMMIT:
        raise ValueError(f"Expected upstream {COMMIT}, got {actual}")
    if subprocess.check_output(["git", "-C", str(source), "status", "--porcelain", "--untracked-files=no"], text=True).strip():
        raise ValueError("Upstream tracked sources must be clean")
    sys.path.insert(0, str(source / "src"))
    import numpy as np
    from PIL import Image, ImageCms, ImageDraw, ImageFont
    from spektrafilm import init_params, digest_params, Simulator

    out = root / "core-study"
    out.mkdir(exist_ok=True)
    base = init_params("kodak_portra_400", "kodak_portra_endura")
    base.io.input_color_space = base.io.output_color_space = "sRGB"
    base.io.input_cctf_decoding = base.io.output_cctf_encoding = True
    base.camera.auto_exposure = False
    base.camera.exposure_compensation_ev = 0
    base.settings.use_enlarger_lut = base.settings.use_scanner_lut = False
    base.debug.deactivate_spatial_effects = True
    base.debug.deactivate_stochastic_effects = True
    base = digest_params(base)
    spatial_reference = digest_params(init_params("kodak_portra_400", "kodak_portra_endura"))
    sigma = spatial_reference.film_render.dir_couplers.diffusion_size_um
    icc = ImageCms.ImageCmsProfile(ImageCms.createProfile("sRGB")).tobytes()
    report = {"source_commit": COMMIT, "source": "https://github.com/andreavolpato/spektrafilm",
              "method": "Portra400/Endura, sRGB in/out, 0EV, auto-exposure off; all other spatial/stochastic effects and scanner sharpening off. Same decoded input per variant, maximum edge 768.",
              "scope": "Upstream mechanism ablation, not a JustShoot migration or physical-film validation",
              "variants": {}, "scenes": {}}
    # Equal RGB chips in different neighborhoods distinguish local chemistry from
    # an operation that genuinely depends on surrounding density.
    neighborhood = np.empty((256, 768, 3), dtype=np.uint8)
    neighborhood[:, :384] = 32
    neighborhood[:, 384:] = 224
    neighborhood[64:192, 188:196] = neighborhood[64:192, 572:580] = 128
    Image.fromarray(neighborhood).save(out / "neighborhood-input.png")
    scenes = ["portrait-daylight", "portrait-window", "neon", "controls", "neighborhood"]
    outputs = {}
    for variant in ["off", "local", "spatial"]:
        params = copy.deepcopy(base)
        params.film_render.dir_couplers.active = variant != "off"
        if variant == "spatial":
            params.film_render.dir_couplers.diffusion_size_um = sigma
        couplers = params.film_render.dir_couplers
        report["variants"][variant] = dataclasses.asdict(couplers)
        simulator = Simulator(params)
        for scene in scenes:
            path = out / "neighborhood-input.png" if scene == "neighborhood" else root / "inputs" / f"{scene}.png"
            im = Image.open(path).convert("RGB")
            im.thumbnail((768, 768), Image.Resampling.LANCZOS)
            rgb = np.asarray(im, dtype=np.float64) / 255
            result = simulator.process(rgb)
            if not np.isfinite(result).all():
                raise ValueError("Nonfinite output")
            outputs[(variant, scene)] = result
            Image.fromarray(np.round(np.clip(result, 0, 1) * 255).astype("uint8")).save(
                out / f"{scene}-{variant}.png", icc_profile=icc)
            report["scenes"].setdefault(scene, {"input_sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
                "dimensions": list(im.size), "variants": {}})["variants"][variant] = {
                    "minimum": float(result.min()), "maximum": float(result.max()),
                    "out_of_gamut_fraction": float(np.mean((result < 0) | (result > 1)))}
            print(f"coupler_ablation variant={variant} scene={scene}", flush=True)
    for scene in scenes:
        for a, b in [("off", "local"), ("local", "spatial")]:
            delta = outputs[(b, scene)] - outputs[(a, scene)]
            report["scenes"][scene][f"{a}_to_{b}"] = {
                "mean_absolute_rgb_codes": float(np.abs(delta).mean() * 255),
                "maximum_absolute_rgb_codes": float(np.abs(delta).max() * 255),
                "mean_absolute_luma_codes": float(np.abs(delta @ np.array([.2126, .7152, .0722])).mean() * 255)}
    probes = {}
    for variant in ["off", "local", "spatial"]:
        first, second = outputs[(variant, "neighborhood")][128, [188, 572]]
        difference = float(np.max(np.abs(first - second)))
        probes[variant] = {"left_rgb": first.tolist(), "right_rgb": second.tolist(),
                           "maximum_rgb_difference": difference}
        if variant != "spatial" and difference > 1e-10:
            raise AssertionError("Local chemistry must map equal input RGB to equal output RGB")
        if variant == "spatial" and difference <= 1e-6:
            raise AssertionError("Spatial DIR must respond to different neighborhoods")
    report["equal_rgb_different_neighborhoods"] = probes
    (out / "metrics.json").write_text(json.dumps(report, indent=2) + "\n")
    font = ImageFont.truetype("/System/Library/Fonts/STHeiti Medium.ttc", 22)
    canvas = Image.new("RGB", (1200, 790), "#15191f")
    draw = ImageDraw.Draw(canvas)
    for i, (variant, title) in enumerate([("off", "Spektrafilm · 关闭 DIR"), ("local", "Spektrafilm · 层间 DIR"),
                                        ("spatial", "Spektrafilm · 加入空间 DIR")]):
        draw.text((i * 400 + 8, 12), title, font=font, fill="white")
        for j, scene in enumerate(["portrait-daylight", "neon"]):
            im = Image.open(out / f"{scene}-{variant}.png").convert("RGB")
            im.thumbnail((388, 350), Image.Resampling.LANCZOS)
            canvas.paste(im, (i * 400 + (400 - im.width) // 2, 52 + j * 360))
    canvas.save(out / "dir-ablation.jpg", quality=96)
    print(json.dumps({"output": str(out), "variants": 3, "scenes": len(scenes)}), flush=True)


if __name__ == "__main__":
    main()
