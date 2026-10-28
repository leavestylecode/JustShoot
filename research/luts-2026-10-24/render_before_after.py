#!/usr/bin/env python3
"""Render old loaded LUT versus replacement LUT on identical sRGB photographs.

Research artifact only. Dependencies: requirements.txt, scikit-image==0.25.2,
Pillow==13.0.0. Legacy preparation mirrors the archived revision's Float32 toe,
33-cube resampling, natural cubic spline and neutral-axis portrait calibration.
Neither side uses exposure/AWB changes, user curves, optics or grain.
"""
from pathlib import Path
import hashlib
import json
import struct
import subprocess
import sys
import zipfile

import numpy as np
from PIL import Image, ImageCms, ImageDraw, ImageFont, ImageOps
from scipy.interpolate import CubicSpline
from skimage import data

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
from bake_film_luts import read_table, sample

OUTPUT = HERE / "before-after"
FONT = "/System/Library/Fonts/STHeiti Medium.ttc"
POINTS = {
    "KodakPortra400": [(0, 0), (.12, .145), (.30, .325), (.60, .575), (.82, .805), (1, 1)],
    "FujiPro400H": [(0, 0), (.12, .140), (.30, .315), (.60, .585), (.82, .810), (1, 1)],
}
NAMES = {
    "FujiC200": "FUJI C200", "FujiPro400H": "FUJI PRO 400H",
    "FujiProvia100F": "FUJI PROVIA 100F", "KodakPortra400": "KODAK PORTRA 400",
    "KodakVision5219": "KODAK VISION3 500T / 5219",
    "KodakVision5203": "KODAK VISION3 50D / 5203",
    "Kodak5207": "KODAK VISION3 250D / 5207", "HarmanPhoenix200": "HARMAN PHOENIX 200",
}


def decode_compiled(raw):
    magic, dimension, count = struct.unpack("<8sII", raw[:16])
    assert magic == b"JSLUT001" and count == dimension**3 * 4
    values = np.frombuffer(raw, dtype="<f4", offset=16).reshape(dimension, dimension, dimension, 4)
    assert np.all(values[..., 3] == 1) and np.isfinite(values).all()
    return values[..., :3].copy()


def legacy_prepared(table, name):
    # FilmProcessor.applyingShadowToe: operate on source nodes BEFORE interpolation.
    t, strength = np.float32(.16), np.float32(.22)
    distance = (t - table) / t
    table = np.where(table < t, table + strength * distance * distance * t, table).astype(np.float32)
    if name not in POINTS:
        return table
    # CurveLUTComposer.preparedSource: double-precision trilinear -> Float32, red-fast.
    blue, green, red = np.meshgrid(*[np.linspace(0, 1, 33)] * 3, indexing="ij")
    table = sample(table, np.stack([red, green, blue], -1)).astype(np.float32)
    # CurveMath.expand uses Float32 control points, Double natural spline, 256 Float32 samples.
    points = np.array(POINTS[name], dtype=np.float32).astype(np.float64)
    curve = np.clip(CubicSpline(points[:, 0], points[:, 1], bc_type="natural")(
        np.linspace(0, 1, 256)), 0, 1).astype(np.float32)
    rgb = table
    luma = rgb[..., 0] * np.float32(.2126) + rgb[..., 1] * np.float32(.7152) + rgb[..., 2] * np.float32(.0722)
    position = np.clip(luma, 0, 1) * np.float32(255)
    lower = position.astype(int)
    fraction = position - lower.astype(np.float32)
    mapped = curve[lower] * (1 - fraction) + curve[np.minimum(lower + 1, 255)] * fraction
    if name == "FujiPro400H":
        distance = np.maximum(np.float32(.30) - mapped, 0)
        smooth = np.clip((mapped - np.float32(.075)) / (np.float32(.12) - np.float32(.075)), 0, 1)
        mapped += distance * distance * np.float32(.20) * (smooth * smooth * (3 - 2 * smooth))
    chroma = rgb - luma[..., None]
    scale = np.ones_like(luma)
    for c in range(3):
        component = chroma[..., c]
        limit = np.ones_like(luma)
        np.divide(1 - mapped, component, out=limit, where=component > 0)
        np.divide(-mapped, component, out=limit, where=component < 0)
        scale = np.minimum(scale, limit)
    return (mapped[..., None] + chroma * np.maximum(scale, 0)[..., None]).astype(np.float32)


def font(size):
    return ImageFont.truetype(FONT, size)


def rgb_image(rgb):
    return Image.fromarray(np.rint(np.clip(rgb, 0, 1) * 255).astype("uint8"))


def save(image, path):
    profile = ImageCms.ImageCmsProfile(ImageCms.createProfile("sRGB")).tobytes()
    image.save(path, quality=96, subsampling=0, icc_profile=profile)


def main():
    OUTPUT.mkdir(exist_ok=True)
    archive = zipfile.ZipFile(HERE / "bundled-before-replacement.zip")
    baseline = archive.read("base-commit.txt").decode().strip()
    sources = {}
    for filename in ["FilmProcessor.swift", "FilmLUTCalibration.swift", "CurveLUTComposer.swift", "CurvePreset.swift"]:
        content = subprocess.check_output(["git", "-C", str(ROOT), "show", f"{baseline}:JustShoot/{filename}"])
        sources[filename] = hashlib.sha256(content).hexdigest()
    stocks = json.loads((ROOT / "JustShoot/Resources/LUTProvenance.json").read_text())["stocks"]
    photos = [("人像", "Eileen Collins / NASA", data.astronaut()),
              ("静物", "Andreas Praefcke", data.coffee()),
              ("夜景", "SpaceX", data.rocket())]
    overview = Image.new("RGB", (2080, 1492), "#14171d")
    od = ImageDraw.Draw(overview)
    od.text((24, 14), "八款胶片 LUT · 替换前后对照", font=font(35), fill="white")
    od.text((24, 60), "每组左：替换前   右：替换后 ｜ 同一输入、相同曝光", font=font(25), fill="#bdc5d0")
    manifest = {"baselineCommit": baseline, "legacyPreparationSourceSHA256": sources,
                "method": "Python mirror of old loaded Float32 LUT (toe then portrait calibration) versus current LUT; trilinear interpolation in encoded sRGB",
                "settings": "Same input. No auto exposure/AWB, user curves, optics or grain. Diagnostic comparison, not full camera output or paired film measurements.",
                "photos": [{"scene": n, "credit": c, "pixelSHA256": hashlib.sha256(a.tobytes()).hexdigest()} for n, c, a in photos],
                "stocks": []}
    # Verify the sampler and the toe independently before using them in comparisons.
    b, g, r = np.meshgrid(*[np.linspace(0, 1, 3)] * 3, indexing="ij")
    identity = np.stack([r, g, b], -1)
    probes = np.random.default_rng(24).random((512, 3))
    np.testing.assert_allclose(sample(identity, probes), probes, atol=1e-14)
    assert abs(float(legacy_prepared(np.zeros((2, 2, 2, 3), dtype=np.float32), "other")[0, 0, 0, 0]) - .0352) < 1e-7
    for i, stock in enumerate(stocks):
        name = stock["resourceName"]
        archived = archive.read(name + ".jslut")
        old = legacy_prepared(decode_compiled(archived), name)
        new = read_table(ROOT / "JustShoot/Resources" / (name + ".cube"))
        assert len(old) == (33 if name in POINTS else 25)
        assert np.isfinite(old).all() and old.min() >= -1e-6 and old.max() <= 1 + 1e-6
        # Cross-check new serialization against independently recorded source reference colors.
        anchors = np.array([s["input"] for s in stock["referenceSamples"]])
        outputs = np.array([s["output"] for s in stock["referenceSamples"]])
        np.testing.assert_allclose(sample(new, anchors), outputs, atol=2e-6)
        left, top = 24 + (i % 4) * 514, 108 + (i // 4) * 674
        od.text((left, top), NAMES[name], font=font(22), fill="white")
        od.text((left + 6, top + 31), "替换前", font=font(22), fill="#ffcc8f")
        od.text((left + 260, top + 31), "替换后", font=font(22), fill="#86dec1")
        full = Image.new("RGB", (1192, 1592), "#14171d")
        fd = ImageDraw.Draw(full)
        fd.text((20, 13), NAMES[name], font=font(32), fill="white")
        fd.text((20, 60), "替换前", font=font(28), fill="#ffcc8f")
        fd.text((616, 60), "替换后", font=font(28), fill="#86dec1")
        y = 101
        for row, (scene, credit, array) in enumerate(photos):
            original = Image.fromarray(array)
            height = round(576 * original.height / original.width)
            rgb = np.asarray(original.resize((576, height), Image.Resampling.LANCZOS)) / 255
            fd.text((20, y), scene, font=font(22), fill="#bdc5d0")
            y += 29
            for col, table in enumerate([old, new]):
                transformed = rgb_image(sample(table, rgb))
                full.paste(transformed, (20 + col * 596, y))
                # Render thumbnails from the same source independently at the overview size.
                small_input = np.asarray(ImageOps.fit(original, (246, 194), Image.Resampling.LANCZOS)) / 255
                overview.paste(rgb_image(sample(table, small_input)),
                    (left + col * 254, top + 64 + row * 200))
            y += height + 8
        full = full.crop((0, 0, 1192, y + 64))
        ImageDraw.Draw(full).text((20, y + 4), "同一输入；无颗粒/光晕/用户曲线。原图：NASA · Praefcke · SpaceX", font=font(19), fill="#bdc5d0")
        save(full, OUTPUT / (name + ".jpg"))
        # A compact portrait pair is convenient for inline display.
        if name == "KodakPortra400":
            save(full.crop((0, 0, 1192, 101 + 29 + 576)), OUTPUT / "Portra400-portrait.jpg")
        manifest["stocks"].append({"resourceName": name, "oldCompiledSHA256": hashlib.sha256(archived).hexdigest(),
            "oldLoadedDimension": len(old), "newDimension": len(new), "newCubeSHA256": stock["sha256"],
            "oldPreparation": "shadow toe" + (" then portrait calibration" if name in POINTS else ""),
            "output": name + ".jpg"})
    od.text((24, 1460), "仅对比加载后的 LUT 调色；旧版包含旧暗部提亮及人像校正。样图：NASA · Praefcke · SpaceX", font=font(21), fill="#bdc5d0")
    save(overview, OUTPUT / "all-eight-before-after.jpg")
    (OUTPUT / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
    (OUTPUT / "README.txt").write_text("每组左边为替换前，右边为替换后。旧版读取原始备份 .jslut，先按历史代码应用 shadow toe；Portra 400 与 Pro 400H 再重采样至 33³ 并应用旧人像校正。新版直接读取当前 LUT。两边都关闭曝光/白平衡调整、用户曲线、颗粒和光学效果；这比较的是加载后的 LUT 调色，不是完整相机成片。Python 按存档 Swift 代码复现旧数值处理；三线性插值使用编码 sRGB。同一组 scikit-image 示例图：Eileen Collins/NASA、Andreas Praefcke、SpaceX。manifest.json 记录基础提交、源代码与色表哈希。\n")
    print(f"Wrote 8 detailed sheets, an overview, and Portra portrait pair to {OUTPUT}")


if __name__ == "__main__":
    main()
