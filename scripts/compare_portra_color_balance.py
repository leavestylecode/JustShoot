#!/usr/bin/env python3
"""Review native Portra v1/v2 exports alongside existing Spektrafilm output.

Run FilmColorBalanceTests with JUSTSHOOT_SCENE_FIXTURES and
JUSTSHOOT_COLOR_BALANCE_EXPORT=<research-root>/fusion-v2/native first. All images
are real renderer outputs; this script only arranges them and measures changes.
"""
from __future__ import annotations

import argparse
import hashlib
import html
import json
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFont

LUMA = np.array([0.2126, 0.7152, 0.0722])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--research-root", required=True, type=Path)
    args = parser.parse_args()
    root = args.research_root.resolve()
    out = root / "fusion-v2"
    manifest = json.loads((root / "manifest.json").read_text())
    scenes = manifest["scenes"]
    report = {"scope": "Portra 400 only; aesthetic color adjustment, no physical-film ground truth",
              "method": "Native iOS CI RGBAf, fixed SDR input, WB neutral, default curve, seed 123. All three native variants use identical optics/grain/density/print tables.",
              "limits": ["Spektrafilm retains its original exposure and scanner sharpening; its darkness and sharpness are not matching targets.",
                         "Input-color gates can also affect wood, clothing and other warm objects.",
                         "Encoded-sRGB luma preservation is not a claim of perceptual brightness or scene-radiance preservation."],
              "baseline": "First color-balance response (v1); archived fusion/native after images",
              "scenes": {}}
    for scene in scenes:
        name = scene["id"]
        record = report["scenes"][name] = {"modes": {}}
        for mode in ("color", "full"):
            paths = [out / "native" / f"{name}-{variant}-{mode}.png" for variant in ("before", "v1", "after")]
            original, before, after = [np.asarray(Image.open(p).convert("RGB"), dtype=np.float64) / 255 for p in paths]
            archived = np.asarray(Image.open(root / "fusion" / "native" / f"{name}-after-{mode}.png").convert("RGB"))
            baseline_delta = np.abs(np.rint(before * 255).astype(np.int16) - archived.astype(np.int16))
            archived_original = np.asarray(Image.open(root / "justshoot" / f"portra400-{name}-{mode}.png").convert("RGB"))
            delta_luma = (after - before) @ LUMA
            record["modes"][mode] = {
                "original_maximum_difference_8bit": int(np.abs(np.rint(original * 255) - archived_original).max()),
                "baseline_matches_archived_pixels": bool(np.array_equal(np.rint(before * 255).astype(np.uint8), archived)),
                "baseline_maximum_difference_8bit": int(baseline_delta.max()),
                "baseline_changed_channels": int(np.count_nonzero(baseline_delta)),
                "mean_absolute_luma_change_8bit": float(np.abs(delta_luma).mean() * 255),
                "maximum_absolute_luma_change_8bit": float(np.abs(delta_luma).max() * 255),
                "mean_absolute_rgb_change_8bit": float(np.abs(after - before).mean() * 255),
                "sha256": {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}}
    (out / "metrics.json").write_text(json.dumps(report, indent=2) + "\n")

    font_path = "/System/Library/Fonts/STHeiti Medium.ttc"
    font = ImageFont.truetype(font_path, 23)
    small = ImageFont.truetype(font_path, 18)
    def board(filename, selected):
        width, row_height = 450, 410
        canvas = Image.new("RGB", (width * 3, 58 + row_height * len(selected)), "#14171c")
        draw = ImageDraw.Draw(canvas)
        for column, title in enumerate(("JustShoot · 上一版", "JustShoot · 本轮优化", "Spektrafilm · 参考")):
            draw.text((column * width + 14, 12), title, font=font, fill="white")
        for row, name in enumerate(selected):
            paths = [out / "native" / f"{name}-v1-full.png", out / "native" / f"{name}-after-full.png",
                     root / "spektrafilm" / f"portra400-{name}-full.png"]
            for column, path in enumerate(paths):
                im = Image.open(path).convert("RGB")
                im.thumbnail((width - 16, row_height - 36), Image.Resampling.LANCZOS)
                y = 58 + row * row_height
                draw.text((column * width + 12, y), name, font=small, fill="#bfc9d4")
                canvas.paste(im, (column * width + (width - im.width) // 2, y + 28))
        canvas.save(out / filename, quality=95)
    board("portraits.jpg", ["portrait-window", "portrait-daylight", "portrait-backlit"])
    board("scenes.jpg", ["neon", "cafe-sunlight", "forest", "flowers"])

    buttons = "".join(f'<button data-scene="{s["id"]}">{html.escape(s["label"])}</button>' for s in scenes)
    page = """<!doctype html><html lang="zh-CN"><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>Portra 第二轮优化对比</title>
<style>body{margin:0;background:#11151b;color:#e3e7ed;font:16px system-ui;line-height:1.65}main{max-width:1800px;margin:auto;padding:24px}h1{font-size:28px}p{max-width:1050px}.toolbar{position:sticky;top:0;background:#11151bf5;padding:10px 0;z-index:2}button,select{background:#232c38;color:white;border:1px solid #536379;border-radius:7px;padding:9px;margin:4px;cursor:pointer}button.active{background:#236fa8}.grid{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:12px}.frame{height:66vh;overflow:auto;background:#080b0e}img{display:block;max-width:100%;max-height:100%;margin:auto;object-fit:contain}body.pixel .frame img{max-width:none;max-height:none}.label{font-size:18px;margin:6px}a{color:#83bdf7}.note{color:#aeb8c8}summary{cursor:pointer}@media(max-width:750px){main{padding:12px}h1{font-size:23px;margin:12px 0}.grid{gap:5px}.frame{height:34vh}.label{font-size:12px;margin:4px 0}section>a{font-size:12px}p{font-size:14px}.toolbar{padding:5px 0}button,select{padding:7px;margin:3px;font-size:12px}}</style>
<main><a href="../fusion/index.html">第一轮融合对比</a> · <a href="../review/index.html">原始项目对比</a><h1>Portra 400 · 第二轮优化</h1>
<p>收敛人像橙红，保留第一轮暗部修正与原有亮度曲线。</p>
<details><summary>本轮改动</summary><p>扩大偏红肤色的修正范围，进一步收敛额外的橙红和饱和度。逆光暖色及颗粒仍保留。中间列为本轮代码的原生导出。</p><p class="note">同一输入、默认曲线、中性白平衡、固定颗粒 seed 123。Spektrafilm 仍为此前默认参考，未调亮或关闭扫描锐化。此次只改 Portra，其他胶片保持原样。</p></details>
<div class="toolbar"><select id="baseline" aria-label="左侧对照"><option value="v1">对照：上一版</option><option value="before">对照：最初版</option><option value="source">对照：输入照片</option></select><select id="mode" aria-label="效果"><option value="full">完整效果</option><option value="color">纯色彩</option></select><button id="pixel" aria-pressed="false">100% 像素</button><div>SCENE_BUTTONS</div></div>
<div class="grid"><section><div class="label" id="baseline-label">JustShoot · 上一版</div><div class="frame"><img id="before" alt="对照照片"></div><a id="before-link" target="_blank">原尺寸 PNG</a></section><section><div class="label">JustShoot · 本轮优化</div><div class="frame"><img id="after" alt="JustShoot 本轮优化"></div><a id="after-link" target="_blank">原尺寸 PNG</a></section><section><div class="label">Spektrafilm · 参考</div><div class="frame"><img id="reference" alt="Spektrafilm 默认参考"></div><a id="reference-link" target="_blank">原尺寸 PNG</a></section></div>
<p id="description" class="note"></p><details><summary>查看原始输入</summary><img id="source" alt="原始 SDR 输入" style="max-height:65vh"></details>
<details><summary>验证与边界</summary><p>iPhone 17 / iOS 26.4 Simulator / Debug，Core Image RGBAf，8bit sRGB PNG 导出。8 张公开照片和 1 张合成测试图；测试核验静态/Live Photo 的浮点输出一致。颜色门控依据输入颜色，木头、衣物等相近颜色也可能变化。保留的是编码 sRGB 亮度加权值，不代表物理光能或严格感知亮度不变；PNG 量化也会产生微小差异。</p><p>本轮通过灰阶、肤色高光渐变和 17³ 色彩体检查亮度与范围；未增加模糊、锐化或高光压缩。第一轮配方和更早配方均保留旧效果；响应版本与参数随新任务冻结。没有实拍胶片扫描真值，也没有设备性能结论。<a href="metrics.json">图像变化与基线核验</a> · <a href="../manifest.json">原图来源</a></p></details>
<script>const scenes=SCENES_JSON;let scene='portrait-window';function update(){const mode=document.getElementById('mode').value;const baseline=document.getElementById('baseline').value;document.getElementById('baseline-label').textContent=baseline==='v1'?'JustShoot · 上一版':baseline==='before'?'JustShoot · 最初版':'输入照片';const paths={before:baseline==='source'?'../inputs/'+scene+'.png':'native/'+scene+'-'+baseline+'-'+mode+'.png',after:'native/'+scene+'-after-'+mode+'.png',reference:'../spektrafilm/portra400-'+scene+'-'+mode+'.png'};for(const [id,path] of Object.entries(paths)){document.getElementById(id).src=path;document.getElementById(id+'-link').href=path;}document.getElementById('source').src='../inputs/'+scene+'.png';document.querySelectorAll('[data-scene]').forEach(b=>{const selected=b.dataset.scene===scene;b.classList.toggle('active',selected);b.setAttribute('aria-pressed',String(selected));});const s=scenes.find(x=>x.id===scene);document.getElementById('description').textContent=s.label+' · '+s.width+' × '+s.height;}document.querySelectorAll('[data-scene]').forEach(b=>b.onclick=()=>{scene=b.dataset.scene;update()});document.getElementById('mode').onchange=update;document.getElementById('baseline').onchange=update;document.getElementById('pixel').onclick=function(){const active=document.body.classList.toggle('pixel');this.setAttribute('aria-pressed',String(active));this.textContent=active?'适应窗口':'100% 像素';};update();</script></main></html>"""
    page = page.replace("SCENE_BUTTONS", buttons).replace("SCENES_JSON", json.dumps(scenes, ensure_ascii=False))
    (out / "index.html").write_text(page)
    matches = sum(m["baseline_matches_archived_pixels"] for s in report["scenes"].values() for m in s["modes"].values())
    print(json.dumps({"scenes": len(scenes), "baseline_pixel_matches": matches, "page": str(out / "index.html")}))


if __name__ == "__main__":
    main()
