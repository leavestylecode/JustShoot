#!/usr/bin/env python3
"""Audit the actual bundled display cubes on normalized SDR scene fixtures.

Usage: python audit_film_scenes.py --samples /path/to/normalized-pngs
    --production /path/to/FilmSceneParityTests-exports --output /path/to/report
Requires numpy, Pillow and scikit-image (the existing LUT research environment).
No network, exposure fitting, LUT rewriting or RAW calibration is performed.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import struct
from importlib.metadata import version
from pathlib import Path

import numpy as np
from PIL import Image, ImageCms, ImageDraw, ImageFont, ImageOps
from skimage.color import rgb2lab

ROOT = Path(__file__).resolve().parents[1]
FILMS = [
    ("fujiProvia100F", "FujiRawPROVIA", "FUJI PROVIA"),
    ("fujiRawVelvia", "FujiRawVelvia", "FUJI Velvia"),
    ("fujiRawASTIA", "FujiRawASTIA", "FUJI ASTIA"),
    ("fujiRawClassicChrome", "FujiRawCLASSICCHROME", "FUJI Classic Chrome"),
    ("fujiRawClassicNeg", "FujiRawCLASSICNeg", "FUJI Classic Neg."),
    ("fujiRawACROS", "FujiRawACROS", "FUJI ACROS"),
    ("fujiC200", "FujiC200", "Fuji C200"),
    ("fujiPro400H", "FujiPro400H", "Fuji Pro 400H"),
    ("kodakPortra400", "KodakPortra400", "Kodak Portra 400"),
]
SCENES = {
    "skin": {"label": "肤色", "credit": "Eileen Collins / NASA; scikit-image astronaut",
             "source": "https://scikit-image.org/docs/stable/api/skimage.data.html#skimage.data.astronaut",
             "note": "已显影的人像；仅有一种实际人物肤色，另以四组不同明度 RGB 肤色探针补充数值压力检查。"},
    "daylight": {"label": "日光", "credit": "Alan Fink / Kodak Image 19; Maine lighthouse",
                 "source": "https://r0k.us/graphics/kodak/kodim19.html",
                 "note": "EKTACHROME 64 Pro 的 PhotoCD 派生图，已有胶片和扫描影调；只作日光场景压力图，不是日光白平衡或胶片真值。"},
    "night": {"label": "夜景", "credit": "╬ಠ益ಠ) / 2011-03-11 night in Taipei / CC0",
              "source": "https://commons.wikimedia.org/wiki/File:2011-03-11_night_in_Taipei.jpg",
              "note": "已显影的 sRGB 夜景 JPEG，ISO 1000；没有可恢复的 RAW 高光或配对 iPhone 预览。"},
}
LUMA = np.array([0.2126, 0.7152, 0.0722])
ICC = ImageCms.ImageCmsProfile(ImageCms.createProfile("sRGB")).tobytes()


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def read_compiled(path):
    raw = path.read_bytes()
    assert raw[:8] == b"JSLUT001", path
    dimension, count = struct.unpack_from("<II", raw, 8)
    assert 2 <= dimension <= 128 and count == dimension ** 3 * 4
    assert len(raw) == 16 + count * 4
    table = np.frombuffer(raw, dtype="<f4", offset=16).reshape((dimension,) * 3 + (4,))
    assert np.isfinite(table).all()
    return table[..., :3].astype(np.float64)


def sample(table, rgb):
    rgb = np.asarray(rgb, dtype=np.float64)
    shape = rgb.shape
    coords = np.clip(rgb.reshape(-1, 3), 0, 1) * (len(table) - 1)
    lo = np.floor(coords).astype(int)
    hi = np.minimum(lo + 1, len(table) - 1)
    f = coords - lo
    result = np.zeros_like(coords)
    for blue in (0, 1):
        for green in (0, 1):
            for red in (0, 1):
                indices = [hi[:, i] if bit else lo[:, i] for i, bit in enumerate((red, green, blue))]
                weight = np.prod([f[:, i] if bit else 1 - f[:, i] for i, bit in enumerate((red, green, blue))], axis=0)
                result += table[indices[2], indices[1], indices[0]] * weight[:, None]
    return result.reshape(shape)


def metrics(rgb):
    luma = rgb @ LUMA
    return {"encodedLumaP10P50P90": np.quantile(luma, [0.1, 0.5, 0.9]).tolist(),
            "nearBlackPercent": float(np.mean(np.max(rgb, axis=-1) <= 1 / 255) * 100),
            "anyChannelNearClipPercent": float(np.mean(np.max(rgb, axis=-1) >= 254 / 255) * 100)}


def load_rgb(path):
    return np.asarray(Image.open(path).convert("RGB"), dtype=np.float64) / 255


def font(size):
    return ImageFont.truetype("/System/Library/Fonts/STHeiti Medium.ttc", size)


def save(image, path):
    image.save(path, quality=94, subsampling=0, icc_profile=ICC)


def rgb_image(rgb):
    return Image.fromarray(np.uint8(np.round(np.clip(rgb, 0, 1) * 255)))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--samples", required=True, type=Path)
    parser.add_argument("--production", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    (args.output / "inputs").mkdir(exist_ok=True)
    (args.output / "renders").mkdir(exist_ok=True)
    # Independent interpolation sanity check, including endpoints and index order.
    b, g, r = np.meshgrid(*[np.linspace(0, 1, 3)] * 3, indexing="ij")
    identity = np.stack([r, g, b], -1)
    probes = np.random.default_rng(25).random((1024, 3))
    np.testing.assert_allclose(sample(identity, probes), probes, atol=1e-12)
    samples = {name: load_rgb(args.samples / (name + ".png")) for name in SCENES}
    for name in SCENES:
        source = args.samples / (name + ".png")
        destination = args.output / "inputs" / source.name
        if source.resolve() != destination.resolve():
            shutil.copy2(source, destination)
    report = {"date": "2026-10-25", "scope": "Offline SDR scene audit; no paired multi-scene iPhone RAW calibration",
        "pythonPackages": {name: version(name) for name in ("numpy", "Pillow", "scikit-image")},
        "method": "Actual runtime .jslut resources; trilinear encoded-sRGB lookup. Gallery uses production Core Image final-stage exports with grain/optics. Synthetic patch and gray metrics isolate the LUT. No stock LUTs are rewritten.",
        "limits": ["Three already-rendered SDR images cannot establish absolute film/camera accuracy or the best look for all subjects.",
                   "Daylight sample is a film scan with preexisting color rendering. Untagged source is explicitly interpreted as sRGB.",
                   "Exposure sweeps scale decoded linear sRGB of an SDR source; these are numerical stress tests, not recovered RAW exposures.",
                   "Renderer parity uses identical input pixels. It does not measure Apple's different preview and RAW camera processing."],
        "scenes": {name: {**SCENES[name], "sha256": digest(args.samples / (name + ".png")),
                          "inputPath": "inputs/" + name + ".png",
                          "size": list(samples[name].shape[1::-1]), "metrics": metrics(samples[name])} for name in SCENES}, "looks": []}
    skin = np.array([[0.78, 0.59, 0.48], [0.55, 0.39, 0.30], [0.30, 0.19, 0.12], [0.14, 0.09, 0.06]])
    input_lab = rgb2lab(skin.reshape(1, -1, 3))[0]
    galleries = {}
    for name, rgb in samples.items():
        board_height = 160 + ((len(FILMS) + 6) // 6) * 430
        board = Image.new("RGB", (1920, board_height), "#15181d")
        draw = ImageDraw.Draw(board)
        draw.text((24, 17), f"{len(FILMS)} 款 LUT · {SCENES[name]['label']}离线检查", font=font(32), fill="white")
        draw.text((24, 58), "首格原图；其余为 App 成片渲染。相同 sRGB 输入，无曝光/白平衡调整。不是 RAW 对拍。", font=font(21), fill="#bcc6d0")
        draw.text((24, board_height - 54), "来源：" + SCENES[name]["credit"], font=font(17), fill="#bcc6d0")
        thumb = ImageOps.contain(rgb_image(rgb), (296, 380), Image.Resampling.LANCZOS)
        board.paste(thumb, (20 + (296 - thumb.width) // 2, 105 + (380 - thumb.height) // 2))
        draw.text((20, 492), "输入原图", font=font(21), fill="white")
        galleries[name] = board
    for index, (identifier, resource, label) in enumerate(FILMS):
        path = ROOT / "JustShoot/Resources" / (resource + ".jslut")
        table = read_compiled(path)
        gray = np.repeat(np.linspace(0, 1, 1025)[:, None], 3, axis=1)
        gray_output = sample(table, gray)
        gray_luma = gray_output @ LUMA
        gray_drawdown = float(np.max(np.maximum.accumulate(gray_luma) - gray_luma))
        skin_out = sample(table, skin)
        lab = rgb2lab(np.clip(skin_out, 0, 1).reshape(1, -1, 3))[0]
        chroma_in = np.linalg.norm(input_lab[:, 1:], axis=-1)
        chroma_out = np.linalg.norm(lab[:, 1:], axis=-1)
        hue = (np.degrees(np.arctan2(lab[:, 2], lab[:, 1]) - np.arctan2(input_lab[:, 2], input_lab[:, 1])) + 180) % 360 - 180
        monochrome = float(np.mean(chroma_out / chroma_in)) < 0.1
        record = {"id": identifier, "resource": resource, "label": label, "sha256": digest(path), "dimension": len(table),
                  "tableRange": [float(np.min(table)), float(np.max(table))],
                  "gray": {"blackRGB": gray_output[0].tolist(), "whiteRGB": gray_output[-1].tolist(),
                           "monotonicLumaViolations": int(np.sum(np.diff(gray_luma) < -0.00001)),
                           "maximumLumaDrawdown": gray_drawdown,
                           "drawdownIn8BitCodes": gray_drawdown * 255,
                           "drawdownExceedsOne8BitCode": gray_drawdown > 1 / 255,
                           "shadowAt5Percent": sample(table, np.full((1, 3), 0.05))[0].tolist(),
                           "highlightLumaSeparation90To100": float(gray_luma[-1] - gray_luma[922])},
                  "skinProbes": {"syntheticNotMeasuredColorChecker": True, "inputRGB": skin.tolist(),
                                 "outputRGB": skin_out.tolist(), "lightnessDelta": (lab[:, 0] - input_lab[:, 0]).tolist(),
                                 "chromaRatio": (chroma_out / chroma_in).tolist(),
                                 "hueDeltaDegrees": None if monochrome else hue.tolist(), "monochrome": monochrome}, "scenes": {}}
        for name, rgb in samples.items():
            final_path = args.production / (identifier + "-" + name + ".png")
            if not final_path.exists():
                raise FileNotFoundError(f"Run FilmSceneParityTests with export enabled first: {final_path}")
            archived = args.output / "renders" / final_path.name
            if final_path.resolve() != archived.resolve():
                shutil.copy2(final_path, archived)
            final = load_rgb(final_path)
            assert final.shape == rgb.shape
            graded = sample(table, rgb)
            stress = {}
            linear = np.where(rgb <= 0.04045, rgb / 12.92, ((rgb + 0.055) / 1.055) ** 2.4)
            for ev in (-2, 2):
                shifted = linear * (2.0 ** ev)
                encoded = np.where(shifted <= 0.0031308, shifted * 12.92, 1.055 * shifted ** (1 / 2.4) - 0.055)
                stress[str(ev)] = metrics(np.clip(sample(table, encoded), 0, 1))
            record["scenes"][name] = {"lutOnly": metrics(graded), "productionFinal": metrics(final),
                                     "productionPath": "renders/" + final_path.name,
                                     "productionSHA256": digest(final_path), "syntheticExposureStressEV": stress}
            board = galleries[name];draw = ImageDraw.Draw(board)
            cell = index + 1; x = 20 + (cell % 6) * 317; y = 105 + (cell // 6) * 430
            thumb = ImageOps.contain(rgb_image(final), (296, 380), Image.Resampling.LANCZOS)
            board.paste(thumb, (x + (296 - thumb.width) // 2, y + (380 - thumb.height) // 2))
            draw.text((x, y + 387), label, font=font(18), fill="white")
        # Three scene rows, original and final side by side, kept at the same size.
        sheet = Image.new("RGB", (1230, 1240), "#15181d");d = ImageDraw.Draw(sheet)
        d.text((22, 12), label, font=font(30), fill="white")
        d.text((22, 53), "左：输入原图     右：App 渲染（含颗粒/光学）；同一 sRGB 输入，无 RAW 显影。", font=font(20), fill="#bcc6d0")
        for row, name in enumerate(SCENES):
            d.text((22, 91 + row * 374), SCENES[name]["label"], font=font(21), fill="white")
            for column, rgb in enumerate((samples[name], load_rgb(args.production / (identifier + "-" + name + ".png")))):
                im = ImageOps.contain(rgb_image(rgb), (580, 330), Image.Resampling.LANCZOS)
                sheet.paste(im, (22 + column * 608 + (580 - im.width) // 2, 121 + row * 374 + (330 - im.height) // 2))
        save(sheet, args.output / (identifier + ".jpg"))
        report["looks"].append(record)
    for name, image in galleries.items():
        save(image, args.output / f"{name}-all-{len(FILMS)}.jpg")
    (args.output / "report.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({"looks": len(report["looks"]), "sceneRenders": len(FILMS) * len(SCENES), "output": str(args.output)}))


if __name__ == "__main__":
    main()
