#!/usr/bin/env python3
"""Render the serialized latest RAW-input CLFs on clearly labelled sample inputs.

No DNG samples are available in this project. These previews decode existing
sRGB samples, convert them to linear Rec.2020, and apply the actual CLF files.
This cannot undo the source camera rendering and is not a real RAW comparison.
"""
from pathlib import Path
import hashlib
import importlib.metadata
import json
import sys
import zipfile

import numpy as np
import PyOpenColorIO as ocio
from PIL import Image, ImageCms, ImageDraw, ImageFont
from skimage import data

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
from bake_film_luts import read_table, sample

LUT_DIR = HERE / "derived/apple-raw-fujifilm"
OUTPUT = LUT_DIR / "previews"
FONT = "/System/Library/Fonts/STHeiti Medium.ttc"
MATRIX = np.array([[.627403895934699, .329283038377883, .043313065687418],
                   [.069097289358232, .919540395075459, .011362315566309],
                   [.016391438875150, .088013307877226, .895595253247624]])
LABELS = {"PROVIA": "PROVIA", "Velvia": "Velvia", "ASTIA": "ASTIA",
          "CLASSIC-CHROME": "CLASSIC CHROME", "REALA-ACE": "REALA ACE",
          "PRO-Neg.Std": "PRO Neg. Std", "CLASSIC-Neg.": "CLASSIC Neg.",
          "ETERNA": "ETERNA", "ETERNA-BB": "ETERNA BLEACH BYPASS", "ACROS": "ACROS"}
BG, MUTED, ACCENT = "#14171d", "#bdc5d0", "#86dec1"
PROFILE = ImageCms.ImageCmsProfile(ImageCms.createProfile("sRGB")).tobytes()


def font(size):
    return ImageFont.truetype(FONT, size)


def linear_input(encoded):
    encoded = np.asarray(encoded, dtype=np.float64)
    linear = np.where(encoded <= .04045, encoded / 12.92, ((encoded + .055) / 1.055) ** 2.4)
    return np.ascontiguousarray(linear @ MATRIX.T, dtype=np.float32)


def processor(stock):
    path = LUT_DIR / stock["file"]
    assert hashlib.sha256(path.read_bytes()).hexdigest() == stock["sha256"]
    return ocio.Config.CreateRaw().getProcessor(
        ocio.FileTransform(src=str(path.resolve()), interpolation=ocio.INTERP_LINEAR)
    ).getDefaultCPUProcessor()


def apply(cpu, rgb):
    result = linear_input(rgb)
    cpu.applyRGB(result)
    assert np.isfinite(result).all() and result.min() >= -1e-6 and result.max() <= 1 + 1e-6
    return result


def bitmap(rgb):
    return Image.fromarray(np.rint(np.clip(rgb, 0, 1) * 255).astype(np.uint8))


def save(image, name):
    path = OUTPUT / name
    image.save(path, quality=96, subsampling=0, icc_profile=PROFILE)
    return {"file": name, "size": list(image.size), "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}


def pair_sheet(label, mode, photos, mapped):
    width, gap, margin = 576, 20, 20
    heights = [round(width * a.shape[0] / a.shape[1]) for _, _, a in photos]
    image = Image.new("RGB", (2 * width + gap + 2 * margin, 156 + sum(h + 43 for h in heights) + 84), BG)
    d = ImageDraw.Draw(image)
    d.text((margin, 14), f"{label} · 最新 LUT 映射", font=font(32), fill="white")
    d.text((margin, 62), "sRGB 示例线性化演示 · 非 RAW 实拍", font=font(23), fill=MUTED)
    d.text((margin, 108), "输入原图", font=font(26), fill="#ffcc8f")
    d.text((margin + width + gap, 108), "最新官方转换版", font=font(26), fill=ACCENT)
    y = 156
    for i, (scene, _, source) in enumerate(photos):
        d.text((margin, y), scene, font=font(22), fill=MUTED)
        y += 31
        for column, result in enumerate((source / 255, mapped[mode][i])):
            tile = bitmap(result).resize((width, heights[i]), Image.Resampling.LANCZOS)
            image.paste(tile, (margin + column * (width + gap), y))
        y += heights[i] + 12
    d.text((margin, y + 6), "同一输入、曝光与白平衡；无颗粒、光晕或额外调色", font=font(20), fill=MUTED)
    d.text((margin, y + 36), "样图：NASA · Andreas Praefcke · SpaceX", font=font(19), fill=MUTED)
    return image


def overview(scene_index, photos, mapped, stocks):
    scene, _, source = photos[scene_index]
    width, gap, margin, header, label_h = 512, 16, 24, 142, 48
    height = round(width * source.shape[0] / source.shape[1])
    row_h = label_h + height + gap
    image = Image.new("RGB", (4 * width + 3 * gap + 2 * margin, header + 3 * row_h + 66), BG)
    d = ImageDraw.Draw(image)
    d.text((margin, 15), f"最新版富士 LUT · {scene}映射效果", font=font(39), fill="white")
    d.text((margin, 70), "原图 + 10 款官方转换版 ｜ 同一输入、曝光与白平衡", font=font(26), fill=MUTED)
    d.text((margin, 108), "sRGB 示例经线性化后映射 · 非 RAW 实拍", font=font(23), fill="#ffcc8f")
    tiles = [("输入原图", source / 255)] + [(LABELS[s["mode"]], mapped[s["mode"]][scene_index]) for s in stocks]
    for i, (label, result) in enumerate(tiles):
        x, y = margin + (i % 4) * (width + gap), header + (i // 4) * row_h
        d.text((x + 2, y + 7), label, font=font(26), fill="#ffcc8f" if i == 0 else ACCENT)
        image.paste(bitmap(result).resize((width, height), Image.Resampling.LANCZOS), (x, y + label_h))
    x, y = margin + 3 * (width + gap), header + 2 * row_h
    d.rectangle((x, y, x + width, y + label_h + height), fill="#202630")
    for i, text in enumerate(("输入：线性 Rec.2020", "输出：sRGB", "读取实际转换版 CLF 文件", "无颗粒 / 光晕 / 自动增强", "此图用于比较映射风格", "RAW 成片仍需真机验证")):
        d.text((x + 20, y + 22 + i * 42), text, font=font(23), fill="white" if i < 2 else MUTED)
    d.text((margin, image.height - 46), f"原图：{photos[scene_index][1]} ｜ 不代表 iPhone RAW 与富士机内成片对拍", font=font(22), fill=MUTED)
    return image


def provia_comparison(photos, mapped):
    current = read_table(ROOT / "JustShoot/Resources/FujiProvia100F.cube")
    width, gap, margin = 512, 16, 24
    heights = [round(width * a.shape[0] / a.shape[1]) for _, _, a in photos]
    image = Image.new("RGB", (3 * width + 2 * gap + 2 * margin, 170 + sum(h + 44 for h in heights) + 80), BG)
    d = ImageDraw.Draw(image)
    d.text((margin, 15), "PROVIA · 项目当前版与最新转换版", font=font(36), fill="white")
    d.text((margin, 67), "sRGB 示例线性化演示 · 非 RAW 实拍 · 两版模拟的定义不同", font=font(23), fill=MUTED)
    for i, text in enumerate(("输入原图", "项目当前 SFL / Provia 100F", "最新官方 PROVIA 转换版")):
        d.text((margin + i * (width + gap), 119), text, font=font(24), fill=ACCENT if i == 2 else "#ffcc8f")
    y = 170
    for i, (scene, _, source) in enumerate(photos):
        d.text((margin, y), scene, font=font(22), fill=MUTED)
        y += 32
        rgb = source / 255
        for col, result in enumerate((rgb, sample(current, rgb), mapped["PROVIA"][i])):
            image.paste(bitmap(result).resize((width, heights[i]), Image.Resampling.LANCZOS),
                        (margin + col * (width + gap), y))
        y += heights[i] + 12
    d.text((margin, y + 6), "无额外曝光 / 白平衡调整、颗粒、光晕或用户曲线；样图：NASA · Praefcke · SpaceX", font=font(20), fill=MUTED)
    return image


def main():
    OUTPUT.mkdir(parents=True, exist_ok=True)
    stocks = json.loads((LUT_DIR / "manifest.json").read_text())["stocks"]
    assert len(stocks) == 10
    photos = [("人像", "Eileen Collins / NASA", data.astronaut()),
              ("静物", "Andreas Praefcke", data.coffee()),
              ("夜景", "SpaceX", data.rocket())]
    np.testing.assert_allclose(MATRIX @ np.ones(3), np.ones(3), atol=1e-12)
    np.testing.assert_allclose(linear_input(np.array([[0., 0., 0.], [1., 1., 1.]])),
                               [[0, 0, 0], [1, 1, 1]], atol=1e-7)
    mapped, files = {}, []
    manifest = {"kind": "Sample-input style preview, not real RAW capture",
                "inputMethod": "Decode sRGB transfer function, convert linear sRGB to linear Rec.2020/D65, no inverse camera tone mapping or scene reconstruction",
                "matrixLinearSRGBToLinearRec2020": MATRIX.tolist(),
                "exposureEV": 0, "autoWhiteBalance": False, "grain": False, "optics": False,
                "renderer": "OpenColorIO evaluates the actual serialized latest CLF files",
                "packages": {x: importlib.metadata.version(x) for x in ("numpy", "opencolorio", "Pillow", "scikit-image")},
                "sources": [{"scene": n, "credit": c, "dimensions": list(a.shape), "pixelSHA256": hashlib.sha256(a.tobytes()).hexdigest()} for n, c, a in photos],
                "luts": [{"mode": s["mode"], "file": s["file"], "sha256": s["sha256"]} for s in stocks],
                "currentProviaCubeSHA256": hashlib.sha256((ROOT / "JustShoot/Resources/FujiProvia100F.cube").read_bytes()).hexdigest()}
    for stock in stocks:
        mode = stock["mode"]
        cpu = processor(stock)
        mapped[mode] = [apply(cpu, a / 255) for _, _, a in photos]
        name = mode.replace(".", "").replace("-", "_")
        files.append(save(pair_sheet(LABELS[mode], mode, photos, mapped), f"{name}-input-vs-latest.jpg"))
    for i, name in enumerate(("portrait", "still-life", "night")):
        files.append(save(overview(i, photos, mapped, stocks), f"all-ten-{name}.jpg"))
    files.append(save(provia_comparison(photos, mapped), "PROVIA-current-vs-latest.jpg"))
    manifest["files"] = files
    (OUTPUT / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
    (OUTPUT / "README.txt").write_text("最新版 10 款富士官方派生 CLF 的映射演示。all-ten-portrait/still-life/night.jpg 分别为人像/静物/夜景：首格为原图，其他格为指定模拟。每款 input-vs-latest.jpg 左原图、右最新转换版，共三种场景。PROVIA-current-vs-latest.jpg 从左至右为原图、项目当前 SFL Provia 100F、最新官方 PROVIA 转换版；两种模拟定义不同，不代表有实体胶片真值参照。所有源图为已有 sRGB 示例，经 sRGB 解码和线性 Rec.2020 色域转换后，直接读取最新 CLF 文件计算。无法逆转源相机影调处理，不是 RAW 实拍、完整 App 成片或富士相机对拍；未加入曝光/AWB、颗粒、光晕或用户曲线。HDR 输入数值保留能力须另用真实 DNG 验证，这些示例自身没有 RAW 高光信息。图片均嵌入 sRGB ICC。来源为 scikit-image 示例：NASA / Andreas Praefcke / SpaceX；manifest.json 记录输入像素、色表和输出图哈希。\n")
    archive = LUT_DIR.parent / "Fujifilm-latest-LUT-previews.zip"
    with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=6) as z:
        for path in sorted(OUTPUT.iterdir()):
            if path.suffix in (".jpg", ".json", ".txt"):
                z.write(path, arcname=f"previews/{path.name}")
    print(f"Rendered {len(files)} images; archive {archive} ({archive.stat().st_size:,} bytes)")


if __name__ == "__main__":
    main()
