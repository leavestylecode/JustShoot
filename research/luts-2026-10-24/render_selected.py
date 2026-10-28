#!/usr/bin/env python3
"""Diagnostic sRGB comparisons, excluding app optics, grain and auto adjustments.

Use requirements.txt plus scikit-image==0.25.2 and Pillow==13.0.0.
Photos: scikit-image sample data, Eileen Collins/NASA, Andreas Praefcke, SpaceX.
These are not paired digital/film measurements.
"""
from pathlib import Path
import json
import sys
import tempfile
import zipfile

import numpy as np
from PIL import Image, ImageCms, ImageDraw, ImageOps
from skimage import data

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
from bake_film_luts import sample, read_table


def main():
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    stocks = json.loads((ROOT / "JustShoot/Resources/LUTProvenance.json").read_text())["stocks"]
    originals = zipfile.ZipFile(HERE / "bundled-before-replacement.zip")
    photos = [data.astronaut(), data.coffee(), data.rocket()]
    width, height = 250, 200
    thumbs = [np.asarray(ImageOps.fit(Image.fromarray(arr), (width, height),
                  method=Image.Resampling.LANCZOS)) / 255 for arr in photos]
    panel_width, panel_height = width * 2, 32 + height * len(photos)
    canvas = Image.new("RGB", (panel_width * 4, panel_height * 2), (23, 23, 25))
    draw = ImageDraw.Draw(canvas)
    fig, axes = plt.subplots(2, 4, figsize=(16, 7.5), layout="constrained")
    x = np.linspace(0, 1, 1025)
    gray = np.repeat(x[:, None], 3, axis=1)
    for i, stock in enumerate(stocks):
        name = stock["resourceName"]
        selected = read_table(ROOT / "JustShoot/Resources" / (name + ".cube"))
        ox, oy = (i % 4) * panel_width, (i // 4) * panel_height
        draw.text((ox + 6, oy + 3), f"{name} ({len(selected)} cubed)", fill="white")
        draw.text((ox + 6, oy + 17), "Input", fill="#aaaaaa")
        draw.text((ox + width + 6, oy + 17), "Selected LUT", fill="#aaaaaa")
        for j, rgb in enumerate(thumbs):
            for column, transformed in enumerate([rgb, sample(selected, rgb)]):
                im = Image.fromarray(np.round(np.clip(transformed, 0, 1) * 255).astype("uint8"))
                canvas.paste(im, (ox + column * width, oy + 32 + j * height))
        old_path = next(p for p in originals.namelist() if p.endswith("/" + name + ".cube") or p == name + ".cube")
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / (name + ".cube")
            path.write_bytes(originals.read(old_path))
            old = read_table(path)
        ax = axes.flat[i]
        ax.plot(x, sample(old, gray) @ [.2126, .7152, .0722], label="Old raw LUT", color="#999999")
        ax.plot(x, sample(selected, gray) @ [.2126, .7152, .0722], label="Selected raw LUT", color="#147d92")
        ax.plot(x, x, ":", color="#cccccc")
        ax.set(title=name, xlim=(0, 1), ylim=(0, 1), xlabel="Input sRGB code", ylabel="Weighted output sRGB code")
        ax.grid(alpha=.15)
        ax.legend(fontsize=7)
    profile = ImageCms.ImageCmsProfile(ImageCms.createProfile("sRGB")).tobytes()
    canvas.save(HERE / "all-films-selected.jpg", quality=95, icc_profile=profile)
    fig.suptitle("Raw gray responses | excludes old app curves, AWB, optics and grain | not linear luminance")
    fig.savefig(HERE / "replacement-comparison.png", dpi=150)
    plt.close(fig)


if __name__ == "__main__":
    main()
