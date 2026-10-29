#!/usr/bin/env python3
"""Build review artifacts from actual FilmMaterialTests PNG exports.

Requires numpy and Pillow. Never downloads, fits exposure, or modifies app LUTs.
Use --inputs for the normalized fixtures, --renders for simulator exports, and
--manifest research/film-material-2026-10-29/expanded-scenes/manifest.json.
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import json
from pathlib import Path

import numpy as np
from PIL import Image, ImageCms, ImageDraw, ImageFont

ICC = ImageCms.ImageCmsProfile(ImageCms.createProfile("sRGB")).tobytes()
BACKGROUND = "#15191f"
INK = "#edf1f7"
MUTED = "#aab5c4"
STAGES = ("input", "legacy", "material", "legacy-color", "material-color",
          "legacy-optics", "material-optics")
LABELS = ("输入原图", "旧流程 · RGB LUT", "新流程 · 密度＋相纸")
GROUPS = {
    "portraits": ("肤色与逆光", ["portrait-window", "portrait-daylight", "portrait-backlit"]),
    "nature": ("天空、绿植与高饱和色", ["forest", "flowers", "daylight"]),
    "night": ("混合光与霓虹", ["cafe-night", "neon", "night"]),
    "light": ("强光与原有人像", ["cafe-sunlight", "skin"]),
}
CHANGE_TILE_SIZE = 64
CHANGE_THRESHOLD = 4


def font(size):
    return ImageFont.truetype("/System/Library/Fonts/STHeiti Medium.ttc", size)


def save(image, path):
    image.save(path, icc_profile=ICC)


def caption(draw, position, text, size=22, fill=INK):
    draw.text(position, text, font=font(size), fill=fill)


def fitted(board, image, box):
    image = image.copy()
    image.thumbnail((box[2] - box[0], box[3] - box[1]), Image.Resampling.LANCZOS)
    board.paste(image, (int((box[0] + box[2] - image.width) / 2),
                        int((box[1] + box[3] - image.height) / 2)))


def main():
    p = argparse.ArgumentParser(description=__doc__)
    for key in ("manifest", "inputs", "renders", "output"):
        p.add_argument("--" + key, type=Path, required=True)
    a = p.parse_args()
    a.output.mkdir(parents=True, exist_ok=True)
    (a.output / "details").mkdir(exist_ok=True)
    manifest = json.loads(a.manifest.read_text())
    scenes = {s["id"]: s for s in manifest["scenes"]}
    metrics, gallery = {}, []

    def read(name, stage):
        with Image.open(a.renders / f"{name}-{stage}.png") as image:
            return image.convert("RGB")

    for name, scene in scenes.items():
        source = a.inputs / scene["input"]
        assert hashlib.sha256(source.read_bytes()).hexdigest() == scene["sha256"], source
        images = {s: read(name, s) for s in STAGES}
        size = (scene["width"], scene["height"])
        assert all(image.size == size for image in images.values()), name
        # A fixed source-based mask makes comparisons independent of output brightness.
        arrays = {s: np.asarray(image, dtype=np.float32) / 255 for s, image in images.items()}
        luma = arrays["input"] @ np.array([.2126, .7152, .0722], dtype=np.float32)
        bands = {"shadows": luma < .15, "midtones": (luma >= .15) & (luma < .7),
                 "highlights": luma >= .7}
        difference = np.abs(arrays["material"] - arrays["legacy"])
        result = {"size": list(size), "meanAbsoluteRGBCodeDifference": float(difference.mean() * 255),
                  "p95AbsoluteRGBCodeDifference": float(np.quantile(difference, .95) * 255),
                  "sha256": {s: hashlib.sha256((a.renders / f"{name}-{s}.png").read_bytes()).hexdigest()
                             for s in STAGES}}
        stage_differences, change_tiles = {}, {}
        for stage, suffix in (("full", ""), ("color", "-color"), ("optics", "-optics")):
            old = np.asarray(images["legacy" + suffix], dtype=np.int16)
            new = np.asarray(images["material" + suffix], dtype=np.int16)
            delta = np.abs(new - old)
            tiles = []
            marked_pixels = 0
            for y in range(0, size[1], CHANGE_TILE_SIZE):
                for x in range(0, size[0], CHANGE_TILE_SIZE):
                    w, h = min(CHANGE_TILE_SIZE, size[0] - x), min(CHANGE_TILE_SIZE, size[1] - y)
                    if delta[y:y + h, x:x + w].mean() >= CHANGE_THRESHOLD:
                        tiles.append([x, y, w, h])
                        marked_pixels += w * h
            change_tiles[stage] = tiles
            stage_differences[stage] = {
                "meanAbsoluteRGBCodeDifference": float(delta.mean()),
                "p95AbsoluteRGBCodeDifference": float(np.quantile(delta, .95)),
                "maximumAbsoluteRGBCodeDifference": int(delta.max()),
                "markedAreaPercent": marked_pixels / (size[0] * size[1]) * 100,
            }
        result["stageDifferences"] = stage_differences
        scene["stageDifferences"] = stage_differences
        scene["changeTiles"] = change_tiles
        white = np.min(arrays["input"], -1) > 245 / 255
        result["inputWhiteMask"] = {
            "definition": "All three input sRGB channels > 245/255; same pixels in all branches.",
            "pixelCount": int(np.count_nonzero(white)),
            "meanRGB8BitCodes": {s: (arrays[s][white].mean(0, dtype=np.float64) * 255).tolist()
                                if np.any(white) else None for s in STAGES},
        }
        for variant in ("legacy", "material"):
            rgb = arrays[variant]
            residual = rgb - arrays[variant + "-optics"]
            result[variant] = {
                "encodedLumaP01P50P99": np.quantile(rgb @ [.2126, .7152, .0722], [.01, .5, .99]).tolist(),
                "allChannelsNearBlackPercent": float(np.mean(np.max(rgb, -1) <= 1 / 255) * 100),
                "anyChannelNearWhitePercent": float(np.mean(np.max(rgb, -1) >= 254 / 255) * 100),
                "grainResidualRMSIn8BitCodesByInputBand": {
                    b: float(np.sqrt(np.mean(residual[mask] ** 2)) * 255) if np.any(mask) else None
                    for b, mask in bands.items()},
            }
        metrics[name] = result
        # Identical integer crop in every branch. Nearest neighbour preserves source pixels.
        crop = scene["crop"]
        side = min(crop["size"], *size)
        left = min(max(round(crop["center"][0] * size[0] - side / 2), 0), size[0] - side)
        top = min(max(round(crop["center"][1] * size[1] - side / 2), 0), size[1] - side)
        box = (left, top, left + side, top + side)
        scene["cropPixels"] = list(box)
        cropped = [images[s].crop(box).resize((side * 2, side * 2), Image.Resampling.NEAREST)
                   for s in ("input", "legacy", "material")]
        crop_board = Image.new("RGB", (side * 6 + 64, side * 2 + 106), BACKGROUND)
        d = ImageDraw.Draw(crop_board)
        caption(d, (16, 12), scene["label"] + " · 同位置 200% · 无锐化", 22)
        for i, (label, image) in enumerate(zip(LABELS, cropped)):
            x = 16 + i * (side * 2 + 16)
            caption(d, (x, 48), label, 20)
            crop_board.paste(image, (x, 84))
        save(crop_board, a.output / "details" / f"{name}-crop.png")
        # Native resolution files remain linked in the browser; sheets are review thumbnails.
        scene["imageAspect"] = size[0] / size[1]
        thumb = images["input"].copy()
        thumb.thumbnail((180, 120))
        import io
        buffer = io.BytesIO()
        thumb.save(buffer, "JPEG", quality=88, icc_profile=ICC)
        scene["thumbnail"] = "data:image/jpeg;base64," + base64.b64encode(buffer.getvalue()).decode()
        gallery.append(scene)

    for group, (title, names) in GROUPS.items():
        row_h = 590 if group == "portraits" else 410
        board = Image.new("RGB", (1472, 148 + row_h * len(names) + 46), BACKGROUND)
        d = ImageDraw.Draw(board)
        caption(d, (24, 18), "PORTRA 400  /  " + title, 32)
        caption(d, (24, 66), "相同输入、默认参数、固定颗粒种子 123；整体图缩小显示，细节请看 200% 局部", 21, MUTED)
        for c, label in enumerate(LABELS):
            caption(d, (24 + c * 480, 110), label, 24)
        for r, name in enumerate(names):
            y = 148 + r * row_h
            caption(d, (24, y + 4), scenes[name]["label"], 21, MUTED)
            for c, stage in enumerate(("input", "legacy", "material")):
                x = 24 + c * 480
                fitted(board, read(name, stage), (x, y + 38, x + 456, y + row_h - 12))
        caption(d, (24, board.height - 32), "已显影 SDR 素材；此处比较 JustShoot 新旧流程，不能作为真实胶片匹配程度的证明。", 19, MUTED)
        save(board, a.output / f"overview-{group}.png")

    # Color-only branches really disable grain and diffusion in both implementations.
    for name in ("portrait-window", "cafe-sunlight", "neon"):
        s = scenes[name]
        side = s["crop"]["size"]
        box = s["cropPixels"]
        board = Image.new("RGB", (4 * (side * 2 + 16) + 16, side * 2 + 120), BACKGROUND)
        d = ImageDraw.Draw(board)
        caption(d, (16, 12), s["label"] + " · 同位置 200% · 色彩与空间效果分离", 24)
        for c, (stage, label) in enumerate(zip(
                ("legacy-color", "material-color", "legacy", "material"),
                ("旧 · 仅色彩", "新 · 仅色彩", "旧 · 完整效果", "新 · 完整效果"))):
            x = 16 + c * (side * 2 + 16)
            caption(d, (x, 52), label, 22)
            board.paste(read(name, stage).crop(box).resize((side * 2, side * 2), Image.Resampling.NEAREST), (x, 88))
        save(board, a.output / f"stages-{name}.png")

    report = {"method": manifest["comparison"], "limits": manifest["limits"],
              "changeMarkerDefinition": {
                  "tileSizePixels": CHANGE_TILE_SIZE, "meanAbsoluteRGBCodeThreshold": CHANGE_THRESHOLD,
                  "purpose": "Numerical location aid only; threshold is not a visibility or quality criterion.",
              }, "scenes": metrics}
    (a.output / "metrics.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    # The local HTML uses relative PNG URLs and works offline; no CDN or runtime dependencies.
    render_relative = __import__("os").path.relpath(a.renders, a.output)
    data = [{k: s[k] for k in ("id", "label", "author", "source_url", "width", "height", "thumbnail",
                               "stageDifferences", "changeTiles")}
            for s in gallery]
    page = HTML.replace("__SCENES__", json.dumps(data, ensure_ascii=False).replace("<", "\\u003c"))
    page = page.replace("__RENDERS__", json.dumps(render_relative))
    (a.output / "index.html").write_text(page)
    print(json.dumps({"sceneCount": len(scenes), "renderCount": len(scenes) * len(STAGES),
                      "output": str(a.output.resolve()),
                      "meanAbsoluteRGBCodeDifference": {s: round(v["meanAbsoluteRGBCodeDifference"], 3)
                                                        for s, v in metrics.items()}}, ensure_ascii=False))


HTML = r'''<!doctype html>
<html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>JustShoot · Portra 400 新旧流程对比</title>
<style>
:root{color-scheme:dark;font-family:system-ui,sans-serif;background:#101419;color:#edf1f7}*{box-sizing:border-box}
body{margin:0}header{padding:24px 28px 16px;border-bottom:1px solid #303843}h1{font-size:24px;margin:0 0 8px}
p{color:#aab5c4;margin:0;font-size:14px;line-height:1.6}main{display:grid;grid-template-columns:240px 1fr;gap:24px;padding:24px}
nav{display:grid;grid-template-columns:1fr 1fr;gap:10px;align-content:start}button,select,a{font:inherit}button,select{background:#232c37;color:#edf1f7;border:1px solid #414f60;border-radius:8px;padding:9px 12px;cursor:pointer}
button:focus-visible,a:focus-visible,input:focus-visible,select:focus-visible{outline:3px solid #b8db93;outline-offset:3px}
button[aria-pressed=true]{border-color:#b8db93;background:#2d3e2a}nav button{padding:5px;text-align:left;font-size:12px;line-height:1.6}nav img{width:100%;height:76px;object-fit:cover;border-radius:4px}
.toolbar{display:flex;gap:10px;align-items:center;flex-wrap:wrap;margin:0 0 14px}.title{font-size:20px;margin-right:auto}
.viewport{overflow:auto;border:1px solid #303843;border-radius:10px;background:#080b0e;padding:12px;min-height:250px}
.stage{position:relative;margin:auto;overflow:hidden}.stage img{position:absolute;inset:0;width:100%;height:100%;display:block}
.stage svg{position:absolute;inset:0;width:100%;height:100%;pointer-events:none;z-index:2}
.stage svg rect{stroke:#ffd86a;stroke-width:1;fill:#ffd86a12;vector-effect:non-scaling-stroke}
.readout{font-size:13px;color:#aab5c4;margin:0 0 12px;line-height:1.6}.phase{color:#b8db93;margin-left:auto}
.marker-note{color:#ffd86a;font-size:13px;margin:10px 0}.toolbar.secondary{margin-bottom:10px}
.upper{position:absolute;inset:0;clip-path:inset(0 50% 0 0)}.line{position:absolute;top:0;bottom:0;left:50%;width:2px;background:white;pointer-events:none}
.badge{position:absolute;top:12px;z-index:3;background:#101419dd;border:1px solid #566273;padding:5px 9px;border-radius:6px;font-size:12px}.left{left:12px}.right{right:12px}
.slider{display:flex;gap:14px;align-items:center;margin:14px 0;color:#c7d3e2;font-size:14px}.slider span{white-space:nowrap}.slider input{flex:1;min-width:60px;accent-color:#b8db93}
.links{display:flex;gap:16px;flex-wrap:wrap;margin:10px 0 18px}a{color:#b8db93;text-decoration:none}a:hover{text-decoration:underline}
details{border-top:1px solid #303843;padding:12px 0}summary{cursor:pointer;color:#b8db93}.crop{width:100%;display:block;margin-top:16px}.foot{padding:20px 28px;border-top:1px solid #303843;font-size:13px;color:#9ca9b9}
@media(max-width:800px){main{display:block;padding:12px}nav{grid-template-columns:repeat(4,1fr);margin-bottom:20px}nav img{height:60px}header{padding:18px}.toolbar{gap:7px}.title{width:100%}}
</style>
<header><h1>Portra 400 · 11 组实图对比</h1><p>基础色彩沿用同一套胶片／相纸模型；此次主要改变空间效果，尚未证明画质提升。</p></header>
<main><nav id="scenes" aria-label="选择场景"></nav><section>
<div class="toolbar"><strong class="title" id="title"></strong><label>底图 <select id="base"><option value="legacy">旧流程</option><option value="input">输入原图</option></select></label><label>效果 <select id="effect"><option value="full">完整效果</option><option value="color">仅色彩</option><option value="optics">含光晕／柔光，无颗粒</option></select></label><button id="zoom" aria-pressed="false">100% 像素</button></div>
<div class="toolbar secondary"><button id="showOld" aria-pressed="false">整张旧版</button><button id="showNew" aria-pressed="false">整张新版</button><button id="blink" aria-pressed="false">自动交替</button><button id="mark" aria-pressed="false">标记变化区域</button><output class="phase" id="phase" aria-live="off">左新 / 右旧</output></div>
<p class="readout" id="difference"></p>
<div class="viewport" id="viewport"><div class="stage" id="stage"><img id="bottom" alt="旧流程"><div class="upper" id="upper"><img id="top" alt="新流程"></div><svg id="changes" aria-hidden="true" style="display:none"></svg><div class="line" id="line"></div><span class="badge left" id="newLabel">新流程</span><span class="badge right" id="baseLabel">旧流程</span></div></div>
<p class="marker-note" id="markerNote" hidden>黄色框只用于定位：64×64 像素区块的平均 RGB 差 ≥4／255。它不是“肉眼可见”或“画质更好”的判定。</p>
<div class="slider"><span id="leftCaption">全旧</span><input id="slider" type="range" min="0" max="100" value="50" aria-label="新流程覆盖比例"><span>全新</span></div>
<p id="info"></p><div class="links"><a id="originalLink">原图 PNG</a><a id="oldLink">旧流程 PNG</a><a id="newLink">新流程 PNG</a><a id="source" target="_blank" rel="noreferrer">素材来源</a></div>
<details open><summary>同位置 200% 局部（完整效果）：原图 ／ 旧流程 ／ 新流程</summary><img class="crop" id="crop" alt="三组相同位置的两倍像素放大图"></details>
<details><summary>查看方法与限制</summary><p>先选“仅色彩”，点“自动交替”：基础颜色几乎相同。再选“完整效果”，对照窗边人像的白窗帘与逆光人像的背景：新流程亮部更灰。此变化需要校准，不能算作画质升级。颗粒请用 100% 像素查看，缩小画面会减弱差异。</p><p>交替每 0.8 秒切换一次原始 PNG，不放大色差；切换场景、效果或隐藏页面时停止。黄色框只标注数值变化区块，关闭标记可恢复原样查看。数字衡量变化量，不是视觉质量分数。</p><p>“仅色彩”在两个分支都关闭颗粒、光晕、柔光和光学高光肩部。“含光晕／柔光”关闭颗粒。“完整效果”为当前预设默认成片。局部图使用最近邻放大，没有额外锐化。所有分支使用同一输入、默认参数、固定颗粒种子 123。</p><p>这些照片已经显影，可能带有原有降噪、调色或光晕；输入没有重新匹配曝光和白平衡。本页没有 SpektraLab 的同图输出或真实胶片配对，不能据此判断绝对胶片准确度。不同场景分辨率不同，只在同一场景内比较颗粒。</p></details>
</section></main><div class="foot">本页仅引用本地 PNG，保留目录结构即可离线使用。人物与品牌不代表对 JustShoot 的推荐或代言。素材署名、许可与输入校验见上级 manifest.json。</div>
<script>
const scenes=__SCENES__, renders=__RENDERS__, $=id=>document.getElementById(id);
let current=scenes.find(s=>s.id==='portrait-window'),zoom=false,timer=null,marks=false;
const nav=$('scenes');scenes.forEach(s=>{let b=document.createElement('button');let im=document.createElement('img');im.src=s.thumbnail;im.alt='';b.append(im,document.createTextNode(s.label));b.onclick=()=>{current=s;update()};b.dataset.id=s.id;nav.append(b)});
function url(stage){return renders+'/'+current.id+'-'+stage+'.png'}
function resize(){let width=zoom?current.width:Math.min($('viewport').clientWidth-26,Math.max(280,window.innerHeight-350)*current.width/current.height);$('stage').style.width=width+'px';$('stage').style.height=width*current.height/current.width+'px'}
function slide(){const n=Number($('slider').value),base=$('base').value==='input'?'原图':'旧版';$('upper').style.clipPath='inset(0 '+(100-n)+'% 0 0)';$('line').style.left=n+'%';$('line').style.display=n===0||n===100?'none':'block';$('newLabel').hidden=n===0;$('baseLabel').hidden=n===100;$('phase').textContent=n===0?'正在显示：'+base:n===100?'正在显示：新版':'左新 / 右'+base;$('showOld').setAttribute('aria-pressed',n===0);$('showNew').setAttribute('aria-pressed',n===100)}
function stopBlink(){if(timer!==null)clearInterval(timer);timer=null;$('blink').textContent='自动交替';$('blink').setAttribute('aria-pressed','false')}
function show(n){stopBlink();$('slider').value=n;slide()}
function markChanges(){const enabled=marks&&$('base').value==='legacy',count=current.changeTiles[$('effect').value].length;$('changes').style.display=enabled?'block':'none';$('markerNote').hidden=!enabled;$('markerNote').textContent='黄色框仅定位：64×64 像素区块的 RGB 平均差 ≥4／255。'+(count===0?'当前无区块达到此阈值。':'已标记 '+count+' 个区块。')+'不代表肉眼可见或画质更好。';$('mark').setAttribute('aria-pressed',enabled);$('mark').disabled=$('base').value!=='legacy'}
function update(){
    stopBlink();
    const e=$('effect').value,suffix=e==='full'?'':e==='color'?'-color':'-optics';
    const base=$('base').value==='input'?'input':'legacy'+suffix,label=base==='input'?'输入原图':'旧流程';
    $('bottom').src=url(base);$('bottom').alt=current.label+' · '+label;
    $('top').src=url('material'+suffix);$('top').alt=current.label+' · 新流程';
    $('baseLabel').textContent=label;$('showOld').textContent=base==='input'?'整张原图':'整张旧版';
    $('leftCaption').textContent=base==='input'?'全原图':'全旧';$('title').textContent=current.label;
    $('info').textContent=current.width+' × '+current.height+' · '+(current.author||'Pexels，署名见来源页面');
    $('originalLink').href=url('input');$('oldLink').href=url('legacy'+suffix);$('newLink').href=url('material'+suffix);$('source').href=current.source_url;
    $('crop').src='details/'+current.id+'-crop.png';
    const diff=current.stageDifferences[e];
    $('difference').textContent='新旧流程：RGB 平均差 '+diff.meanAbsoluteRGBCodeDifference.toFixed(2)+'／255 · 95% 通道差 ≤'+Math.ceil(diff.p95AbsoluteRGBCodeDifference)+' 级（变化量，不是质量分数）';
    $('changes').setAttribute('viewBox','0 0 '+current.width+' '+current.height);
    $('changes').replaceChildren();
    current.changeTiles[e].forEach(([x,y,w,h])=>{const rect=document.createElementNS('http://www.w3.org/2000/svg','rect');for(const [k,v] of Object.entries({x,y,width:w,height:h}))rect.setAttribute(k,v);$('changes').append(rect)});
    [...nav.children].forEach(b=>b.setAttribute('aria-pressed',b.dataset.id===current.id));
    markChanges();resize();slide();
}
$('slider').oninput=()=>{stopBlink();slide()};$('base').onchange=update;$('effect').onchange=update;
$('zoom').onclick=()=>{zoom=!zoom;$('zoom').setAttribute('aria-pressed',zoom);resize()};
$('showOld').onclick=()=>show(0);$('showNew').onclick=()=>show(100);
$('mark').onclick=()=>{marks=!marks;markChanges()};
$('blink').onclick=()=>{
    if(timer!==null){stopBlink();return}
    $('slider').value=0;slide();$('blink').textContent='停止交替';$('blink').setAttribute('aria-pressed','true');
    timer=setInterval(()=>{if($('top').complete&&$('top').naturalWidth&&$('bottom').complete&&$('bottom').naturalWidth){$('slider').value=Number($('slider').value)===0?100:0;slide()}},800);
};
window.addEventListener('resize',resize);window.addEventListener('pagehide',stopBlink);
document.addEventListener('visibilitychange',()=>{if(document.hidden)stopBlink()});update();
</script></html>'''


if __name__ == "__main__":
    main()
