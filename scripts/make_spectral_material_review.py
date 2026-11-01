#!/usr/bin/env python3
"""Assemble a local review of native exports, with reproducible photo metrics."""
import argparse
import json
from pathlib import Path
import shutil


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--research-root", type=Path, required=True)
    parser.add_argument("--reference", type=Path, required=True)
    args = parser.parse_args()
    import numpy as np
    from PIL import Image, ImageDraw, ImageFont

    root = args.research_root.resolve()
    out = root / "spectral-core"
    shutil.copytree(args.reference, out / "reference", dirs_exist_ok=True)
    manifest = json.loads((root / "manifest.json").read_text())
    scenes = manifest["scenes"] if isinstance(manifest, dict) else manifest
    metrics = {}
    for scene in scenes:
        name = scene["id"]
        def pixels(path):
            return np.asarray(Image.open(path).convert("RGB")).astype(np.int16)
        actual = pixels(out / "native" / f"{name}-core-color.png")
        reference = pixels(out / "reference" / f"{name}.png")
        old = pixels(out / "native" / f"{name}-previous-full.png")
        frozen = pixels(root / "fusion-v2/native" / f"{name}-after-full.png")
        metrics[name] = dict(nativeReferenceRGBP95Codes=float(np.percentile(abs(actual-reference), 95)),
                             nativeReferenceRGBMaxCodes=int(abs(actual-reference).max()),
                             legacyChangedComponents=int(np.count_nonzero(old-frozen)),
                             legacyMaxDifferenceCodes=int(abs(old-frozen).max()))
        if metrics[name]["nativeReferenceRGBMaxCodes"] > 1 or metrics[name]["legacyMaxDifferenceCodes"] > 1:
            raise AssertionError(f"Native/reference or historical-recipe regression: {name}")
    (out / "photo-metrics.json").write_text(json.dumps(metrics, indent=2) + "\n")
    titles = [("previous", "原有 Portra v2"), ("core", "新模型 · 无肤色修饰"), ("balanced", "新默认 · 光谱＋肤色保护")]
    font = ImageFont.truetype("/System/Library/Fonts/STHeiti Medium.ttc", 20)
    for filename, selected in [("portraits.jpg", ["portrait-daylight", "portrait-window", "portrait-backlit"]),
                                ("scenes.jpg", ["neon", "forest", "cafe-sunlight"])]:
        board = Image.new("RGB", (1200, 900), "#171b21")
        draw = ImageDraw.Draw(board)
        for row, name in enumerate(selected):
            for col, (variant, title) in enumerate(titles):
                im = Image.open(out / "native" / f"{name}-{variant}-full.png").convert("RGB")
                im.thumbnail((392, 260), Image.Resampling.LANCZOS)
                board.paste(im, (col * 400 + (400-im.width)//2, row * 300+34))
                draw.text((col*400+8, row*300+6), title, font=font, fill="white")
        board.save(out / filename, quality=96)
    options = "".join(f'<option value="{s["id"]}">{s["label"]}</option>' for s in scenes)
    cards = "".join(f'<figure><figcaption>{title}</figcaption><a id="{key}-link" target="_blank"><img id="{key}" alt="{title}"></a></figure>' for key, title in titles)
    html = '''<!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>JustShoot · 光谱核心重构对比</title><style>
:root{color-scheme:dark;font-family:system-ui,-apple-system,sans-serif;background:#11151b;color:#e8edf4}*{box-sizing:border-box}body{margin:0}main{max-width:1600px;margin:auto;padding:24px}h1{font-size:23px;letter-spacing:-.5px;margin:0 0 9px}p{color:#aebaca;font-size:13px;line-height:1.65;margin:7px 0 17px}nav{display:flex;align-items:center;gap:12px;flex-wrap:wrap;margin:18px 0}label{display:flex;align-items:center;gap:7px;font-size:13px}button,select{font:inherit;border:1px solid #344252;border-radius:9px;background:#1c2531;color:#eef3f8;padding:8px 10px}button{cursor:pointer}.grid{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:12px}figure{margin:0;background:#080b10;border:1px solid #293340;border-radius:12px;overflow:hidden}figcaption{font-size:13px;padding:12px;white-space:nowrap}a{color:#9dcaff}figure a{display:block;overflow:auto;height:65vh;min-height:300px}figure img{display:block;width:100%;height:100%;object-fit:contain}.pixel figure img{width:auto;height:auto;max-width:none}details{margin-top:18px;font-size:13px;line-height:1.7;color:#b8c3d1}summary{cursor:pointer}details img{display:block;max-height:65vh;max-width:100%;margin-top:12px}.note{padding:12px 15px;border:1px solid #30413f;background:#142421;border-radius:10px;color:#bed8ce}footer{display:flex;gap:16px;flex-wrap:wrap;font-size:12px;margin-top:20px}#error{color:#ffb6a8}@media(max-width:640px){main{padding:14px 9px}.grid{gap:5px}figcaption{font-size:10px;padding:8px 4px;white-space:normal;min-height:43px}figure a{height:48vh;min-height:220px}h1{font-size:20px}}
</style><main><h1>Portra：把光谱核心接进原生链路</h1>
<p>相同输入、固定种子 123。三列均由 iOS 原生渲染导出；右列已作为新 Portra 默认配方，旧任务按原版本重算。</p>
<nav><label>场景 <select id="scene">SCENES</select></label><label>阶段 <select id="mode"><option value="full">完整成品</option><option value="color">仅色彩模型</option></select></label><button id="pixel" aria-pressed="false">100% 像素</button></nav>
<div class="grid">CARDS</div><p id="error" role="alert"></p>
<p class="note">新核心包含光谱重建、局部 DIR 层间耦合、胶片密度和相纸／扫描响应。完整成品仍使用 JustShoot 现有颗粒与光学处理；空间 DIR 和粒子统计颗粒尚未迁入。</p>
<details><summary>原图、完整计算参考与验证边界</summary><img id="input" alt="未套用本次胶片效果的输入"><p><a id="source-link" target="_blank">输入照片来源</a> · <a id="reference" target="_blank">Spektrafilm 完整点运算参考</a></p>
<p>8 张已显影 SDR 照片＋1 张合成控制图；无真实胶片扫描真值。参考使用固定输入曝光、局部 DIR 开启、空间／随机效果关闭；未套用 JustShoot 肤色保护。两张 65³ 表离线核对 12,314 样本，P95 ΔE00 0.058，最大 0.151。照片 PNG 是 8 位展示文件；误差详情见记录。</p></details>
<footer><a href="photo-metrics.json">原生照片核对数据</a><a href="REVIEW.txt">实施与验证记录</a><a href="../fusion-v2/index.html">上一轮对比</a><a href="portraits.jpg" target="_blank">人像总览</a><a href="scenes.jpg" target="_blank">场景总览</a></footer>
<script>const scenes=DATA;const scene=document.getElementById('scene'),mode=document.getElementById('mode');scene.value='portrait-window';function update(){document.getElementById('error').textContent='';for(const key of ['previous','core','balanced']){const path='native/'+scene.value+'-'+key+'-'+mode.value+'.png';const im=document.getElementById(key);im.onerror=()=>document.getElementById('error').textContent='图片加载失败，请重新选择场景或刷新页面。';im.src=path;document.getElementById(key+'-link').href=path;}document.getElementById('input').src='../inputs/'+scene.value+'.png';document.getElementById('reference').href='reference/'+scene.value+'.png';const s=scenes.find(x=>x.id===scene.value);const link=document.getElementById('source-link');link.href=s.source_url||'../inputs/'+scene.value+'.png';link.textContent=s.author?'输入照片 · '+s.author:'输入照片来源';}scene.onchange=mode.onchange=update;document.getElementById('pixel').onclick=function(){const active=document.body.classList.toggle('pixel');this.setAttribute('aria-pressed',String(active));this.textContent=active?'适应窗口':'100% 像素';};update();</script></main></html>'''
    (out / "index.html").write_text(html.replace("SCENES", options).replace("CARDS", cards).replace("DATA", json.dumps(scenes, ensure_ascii=False)))
    print(json.dumps(dict(output=str(out), scenes=len(scenes), nativePNGCount=len(list((out/"native").glob("*.png"))),
                          legacyChangedComponents=sum(s["legacyChangedComponents"] for s in metrics.values())), ensure_ascii=False))


if __name__ == "__main__":
    main()
