#!/usr/bin/env python3
"""Compare production CI exports with identical SDR input, texture and optics.

Original on the left is the prior App look, not the ungraded source photograph.
Keeps all inputs/renders outside the repository. No image generation or relighting.
"""
from __future__ import annotations

import argparse
import json
import shutil
from importlib.metadata import version
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageOps
from skimage.color import rgb2lab

from audit_film_scenes import (FILMS, SCENES, ROOT, LUMA, digest, font, load_rgb,
                              metrics, read_compiled, rgb_image, sample, save)
from refine_film_looks import refined_table


def skin_metrics(table):
    skin = np.array([[.78, .59, .48], [.55, .39, .30], [.30, .19, .12], [.14, .09, .06]])
    source = rgb2lab(skin.reshape(1, -1, 3))[0]
    output = rgb2lab(sample(table, skin).reshape(1, -1, 3))[0]
    chroma = np.linalg.norm(output[:, 1:], axis=-1) / np.linalg.norm(source[:, 1:], axis=-1)
    hue = (np.degrees(np.arctan2(output[:, 2], output[:, 1]) - np.arctan2(source[:, 2], source[:, 1])) + 180) % 360 - 180
    return {"lightnessDelta": (output[:, 0] - source[:, 0]).tolist(), "chromaRatio": chroma.tolist(), "hueDeltaDegrees": hue.tolist()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--before", type=Path, required=True)
    parser.add_argument("--after", type=Path, required=True)
    parser.add_argument("--inputs", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    for name in ("before", "after", "inputs"):
        (args.output / name).mkdir(exist_ok=True)
    config_path = ROOT / "JustShoot/Resources/FilmLookRefinements.json"
    config = json.loads(config_path.read_text())
    report = {"date": "2026-10-25", "revision": config["revision"], "configurationSHA256": digest(config_path),
              "pythonPackages": {name: version(name) for name in ("numpy", "Pillow", "scikit-image")},
              "method": "Both columns are App CI final-stage exports. Identical quantized sRGB source, seed, optics and grain. Before uses source LUT; after uses shared refined look.",
              "limits": ["No newly captured RAW scenes or absolute film/skin accuracy measurement.",
                         "Skin gating is based on input color, so similar warm objects may also change.",
                         "Pure black cannot acquire detail; rescue retains existing input separation rather than reconstructing RAW shadows.",
                         "Four synthetic skin probes are relative to source RGB, not measured skin reflectance; near-neutral dark hue angles are unstable.",
                         "LUT-only metrics use the independent double-precision baked reference, cross-checked against Swift in XCTest. Production metrics use actual CI PNG exports."],
              "inputs": {}, "looks": []}
    boards = {}
    for scene, info in SCENES.items():
        path = args.inputs / (scene + ".png")
        shutil.copy2(path, args.output / "inputs" / path.name)
        report["inputs"][scene] = {**info, "sha256": digest(path)}
        board_height = 215 + ((len(FILMS) + 2) // 3) * 330
        board = Image.new("RGB", (1920, board_height), "#15181d")
        draw = ImageDraw.Draw(board)
        draw.text((22, 15), f"{info['label']} · {len(FILMS)} 款优化前后", font=font(32), fill="white")
        description = "每款左：优化前；右：优化后。肤色使用同一区域裁切。" if scene == "skin" else "每款左：优化前；右：优化后。"
        draw.text((22, 58), description + "同输入、曝光、白平衡、颗粒与光学。", font=font(21), fill="#bfc9d4")
        draw.text((22, board_height - 78), "离线 sRGB 成片渲染比较；不是原图对 LUT，也不是 iPhone RAW 对拍。", font=font(19), fill="#bfc9d4")
        draw.text((22, board_height - 45), "来源：" + info["credit"], font=font(16), fill="#bfc9d4")
        boards[scene] = board
    for index, (identifier, resource, label) in enumerate(FILMS):
        source_path = ROOT / "JustShoot/Resources" / (resource + ".jslut")
        before_table = read_compiled(source_path)
        after_table = refined_table(before_table, config["profiles"][identifier])
        record = {"id": identifier, "label": label, "sourceLUTSHA256": digest(source_path),
                  "profile": config["profiles"][identifier], "skinProbesBefore": skin_metrics(before_table),
                  "skinProbesAfter": skin_metrics(after_table), "scenes": {}}
        gray = np.repeat(np.linspace(0, 1, 1025)[:, None], 3, axis=1)
        record["grayMaximumCumulativeReversal"] = {}
        for name, table in (("before", before_table), ("after", after_table)):
            y = sample(table, gray) @ LUMA
            record["grayMaximumCumulativeReversal"][name] = float(np.max(np.maximum.accumulate(y) - y))
        sheet = Image.new("RGB", (1230, 1240), "#15181d")
        draw = ImageDraw.Draw(sheet)
        draw.text((22, 12), label + " · 优化前后", font=font(29), fill="white")
        draw.text((22, 55), "左：此前成片     右：优化后成片；同输入、曝光、白平衡、颗粒与光学。", font=font(20), fill="#bfc9d4")
        for row, scene in enumerate(SCENES):
            path_before = args.before / (identifier + "-" + scene + ".png")
            path_after = args.after / path_before.name
            before, after = load_rgb(path_before), load_rgb(path_after)
            assert before.shape == after.shape
            for name, path in (("before", path_before), ("after", path_after)):
                shutil.copy2(path, args.output / name / path.name)
            source = load_rgb(args.inputs / (scene + ".png"))
            assert source.shape == before.shape
            record["scenes"][scene] = {"before": metrics(before), "after": metrics(after),
                "lutOnlyBefore": metrics(sample(before_table, source)), "lutOnlyAfter": metrics(sample(after_table, source)),
                "beforeSHA256": digest(path_before), "afterSHA256": digest(path_after),
                "meanAbsoluteRGBChange": float(np.mean(np.abs(after - before)))}
            draw.text((22, 92 + row * 374), SCENES[scene]["label"], font=font(21), fill="white")
            for column, rgb in enumerate((before, after)):
                picture = rgb_image(rgb)
                thumb = ImageOps.contain(picture, (580, 330), Image.Resampling.LANCZOS)
                sheet.paste(thumb, (22 + column * 608 + (580 - thumb.width) // 2, 121 + row * 374 + (330 - thumb.height) // 2))
                if scene == "skin":
                    picture = picture.crop((140, 5, 320, 210))
                pair = ImageOps.contain(picture, (296, 270), Image.Resampling.LANCZOS)
                x = 18 + (index % 3) * 635 + column * 310
                y = 122 + (index // 3) * 330
                boards[scene].paste(pair, (x + (296 - pair.width) // 2, y + (270 - pair.height) // 2))
            bd = ImageDraw.Draw(boards[scene])
            bd.text((18 + (index % 3) * 635, 99 + (index // 3) * 330), label, font=font(19), fill="white")
            bd.text((18 + (index % 3) * 635, 399 + (index // 3) * 330), "优化前", font=font(16), fill="#bfc9d4")
            bd.text((328 + (index % 3) * 635, 399 + (index // 3) * 330), "优化后", font=font(16), fill="#bfc9d4")
        save(sheet, args.output / (identifier + "-before-after.jpg"))
        report["looks"].append(record)
    for scene, board in boards.items():
        save(board, args.output / f"{scene}-before-after-all-{len(FILMS)}.jpg")
    (args.output / "report.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({"looks": len(report["looks"]), "pairedRenders": len(FILMS) * len(SCENES), "output": str(args.output)}))


if __name__ == "__main__":
    main()
