#!/usr/bin/env python3
"""Validate native Portra calibration exports against frozen baselines; build review.

Requires NumPy/Pillow. Never overwrites historical spectral-core/native fixtures.
The two fixed portrait ROIs guide aesthetic calibration, not physical-film accuracy.
"""
import argparse
import json
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--research-root', type=Path, required=True)
    args = parser.parse_args()
    import numpy as np
    from PIL import Image, ImageDraw, ImageFont
    root = args.research_root.resolve()
    out = root / 'spectral-calibration'
    scenes = json.loads((root / 'manifest.json').read_text())['scenes']
    weights = np.array([.2126, .7152, .0722])
    def pixels(path):
        return np.asarray(Image.open(path).convert('RGB')).astype(np.float64) / 255
    def linear(a):
        return np.where(a <= .04045, a/12.92, ((a+.055)/1.055)**2.4)
    def tone(a, lift, ceiling, source):
        y = a @ weights
        x = np.clip(y/ceiling, 0, 1)
        t = np.clip((source @ weights)/.12, 0, 1)
        toe = t*t*(3-2*t)
        delta = lift*toe*y*(1-x)**2
        return a + (1-a)*delta[..., None]/np.maximum(1-y[..., None], 1e-6)
    rois = {'portrait-daylight': (.5, .45), 'portrait-window': (.55, .30)}
    # Coarse numerical exploration; visual selection also considers the held-out scenes.
    candidates = []
    for lift in [.35, .5, .65, .8]:
        for ceiling in [.4, .5, .6]:
            row = dict(lift=lift, ceiling=ceiling, rois={})
            for name, (cx, cy) in rois.items():
                old = pixels(root/'spectral-core/native'/f'{name}-previous-color.png')
                a = pixels(root/'spectral-core/native'/f'{name}-balanced-color.png')
                h, w = a.shape[:2]
                x, y = int(cx*w), int(cy*h)
                crop = np.s_[y-128:y+128, x-128:x+128]
                target = (linear(old[crop]) @ weights).mean()
                new = (linear(tone(a, lift, ceiling, pixels(root/'inputs'/f'{name}.png'))[crop]) @ weights).mean()
                row['rois'][name] = float(np.log2(new/target))
            row['sumAbsoluteEVFromOld'] = sum(abs(v) for v in row['rois'].values())
            candidates.append(row)
    (out/'sweep.json').write_text(json.dumps(candidates, indent=2)+'\n')
    result = dict(calibration=dict(shadowLift=.65, toneCeiling=.6, grainScale=.65), scenes={}, rois={})
    for scene in scenes:
        name = scene['id']
        row = {}
        for variant in ['previous', 'core', 'balanced']:
            for mode in ['color', 'full']:
                a = pixels(out/'native'/f'{name}-{variant}-{mode}.png')
                b = pixels(root/'spectral-core/native'/f'{name}-{variant}-{mode}.png')
                difference = np.abs(a-b)*255
                maximum = int(round(difference.max()))
                assert maximum <= 1, f'Frozen rendering changed: {name} {variant} {mode}: {maximum}'
                row[f'{variant}_{mode}_frozenMaxCodes'] = maximum
        before = pixels(out/'native'/f'{name}-balanced-color.png')
        after = pixels(out/'native'/f'{name}-calibrated-color.png')
        predicted = tone(before, .65, .6, pixels(root/'inputs'/f'{name}.png'))
        error = np.abs(predicted-after)*255
        row['tonePredictionP95Codes'] = float(np.percentile(error, 95))
        row['tonePredictionMaxCodes'] = float(error.max())
        assert error.max() <= 2, f'Native tone differs from model: {name}'
        high = before @ weights >= .6
        row['highlightPixels'] = int(high.sum())
        row['highlightMaxCodes'] = float((np.abs(before-after)[high]*255).max()) if high.any() else 0
        assert row['highlightMaxCodes'] <= 1.001, f'Highlight response changed: {name}'
        result['scenes'][name] = row
        if name in rois:
            h, w = before.shape[:2]
            cx, cy = rois[name]; x, y = int(cx*w), int(cy*h)
            crop = np.s_[y-128:y+128, x-128:x+128]
            old = pixels(out/'native'/f'{name}-previous-color.png')
            a, b, c = [(linear(im[crop]) @ weights).mean() for im in [before, after, old]]
            entry = dict(roiCenter=[cx,cy], roiSize=256, beforeLinearY=float(a), afterLinearY=float(b),
                         oldLinearY=float(c), gainedEV=float(np.log2(b/a)),
                         beforeVsOldEV=float(np.log2(a/c)), afterVsOldEV=float(np.log2(b/c)))
            result['rois'][name] = entry
            assert entry['gainedEV'] > (.45 if name == 'portrait-daylight' else .04)
            assert entry['afterVsOldEV'] < .15
    grain_stats = out/'grain/statistics.json'
    if grain_stats.exists():
        stats = json.loads(grain_stats.read_text())
        assert len(stats) == 12, 'Incomplete grain statistics matrix'
        ratios = [s['calibratedDeviation']/s['unscaledDeviation'] for s in stats]
        mean_shift = max(abs(s['calibratedMean']-s['quietMean']) for s in stats)
        assert min(ratios) > .5 and max(ratios) < .8 and mean_shift < .003
        result['grain'] = dict(measurements=len(stats), deviationRatioMin=min(ratios),
                               deviationRatioMax=max(ratios), maxMeanShift=mean_shift)
    result['status'] = 'passed'
    (out/'metrics.json').write_text(json.dumps(result, indent=2)+'\n')
    variants = [('previous','原有 Portra'),('balanced','上一轮光谱版本'),('calibrated','本轮 · 明暗与颗粒校准')]
    font = ImageFont.truetype('/System/Library/Fonts/STHeiti Medium.ttc', 19)
    for filename, names in [('portraits.jpg',['portrait-daylight','portrait-window','portrait-backlit']),
                            ('scenes.jpg',['neon','forest','cafe-sunlight'])]:
        board = Image.new('RGB',(1200,960),'#141a21'); draw = ImageDraw.Draw(board)
        for row, name in enumerate(names):
            for col,(variant,label) in enumerate(variants):
                im = Image.open(out/'native'/f'{name}-{variant}-full.png').convert('RGB')
                im.thumbnail((394,279),Image.Resampling.LANCZOS)
                board.paste(im,(col*400+(400-im.width)//2,row*320+36))
                draw.text((col*400+8,row*320+5),label,font=font,fill='white')
        board.save(out/filename,quality=96)
    board=Image.new('RGB',(960,660),'#141a21');draw=ImageDraw.Draw(board)
    for row,(name,(cx,cy)) in enumerate(rois.items()):
        for col,(variant,label) in enumerate(variants):
            im=Image.open(out/'native'/f'{name}-{variant}-full.png').convert('RGB')
            x,y=int(im.width*cx),int(im.height*cy)
            im=im.crop((x-128,y-128,x+128,y+128)).resize((310,310),Image.Resampling.LANCZOS)
            board.paste(im,(col*320,row*330+26));draw.text((col*320+4,row*330+2),label,font=font,fill='white')
    board.save(out/'crops.jpg',quality=96)
    if grain_stats.exists():
        board = Image.new('RGB',(1280,990),'#141a21');draw=ImageDraw.Draw(board)
        for row,(name,(cx,cy)) in enumerate(list(rois.items()) + [('neon',(.5,.5))]):
            for col,scale in enumerate([45,65,80,100]):
                im=Image.open(out/'grain'/f'{name}-grain-{scale}.png').convert('RGB')
                x,y=int(im.width*cx),int(im.height*cy)
                im=im.crop((x-128,y-128,x+128,y+128)).resize((310,310),Image.Resampling.LANCZOS)
                board.paste(im,(col*320,row*330+26))
                draw.text((col*320+4,row*330+2),f'Grain {scale}%',font=font,fill='white')
        board.save(out/'grain/candidates.jpg',quality=96)
    # Reuse the established review controls and source attributions.
    page=(root/'spectral-core/index.html').read_text()
    page=page.replace('光谱核心重构对比','光谱成片校准对比').replace('Portra：把光谱核心接进原生链路','Portra：校准中间调与颗粒')
    page=page.replace('新模型 · 无肤色修饰','上一轮光谱版本').replace('新默认 · 光谱＋肤色保护','本轮 · 明暗与颗粒校准')
    # Swap IDs via a temporary token so that the historical file names stay explicit.
    page=page.replace('balanced','__NEW__').replace('core','balanced').replace('__NEW__','calibrated')
    page=page.replace('右列已作为新 Portra 默认配方，旧任务按原版本重算。','右列为本轮新配方。相同参数处理全部场景，历史配方保持原版本。')
    page=page.replace('完整成品仍使用 JustShoot 现有颗粒与光学处理；','本轮对输出明暗和经验颗粒强度做了校准；')
    page=page.replace('reference/'+"'", '../spectral-core/reference/'+"'")
    page=page.replace('photo-metrics.json','metrics.json')
    page=page.replace('<a href="../fusion-v2/index.html">上一轮对比</a>','<a href="../spectral-core/index.html">上一轮光谱对比</a><a href="crops.jpg" target="_blank">人像细节</a><a href="sweep.json">参数扫描</a>')
    page=page.replace('<p class="note">','<p class="note">暗部／中间调平滑提升，高亮区域沿用上一轮响应；颗粒密度扰动缩放为上一轮的 65%。')
    if grain_stats.exists():
        page=page.replace('<footer>', '<details><summary>颗粒强度候选</summary><img src="grain/candidates.jpg" alt="45%、65%、80%、100% 颗粒强度比较"><p>固定明暗校准、光学参数和种子；本轮选择 65%。这是经验纹理强度调整，尚非真实胶片颗粒标定。</p></details><footer>')
    # The copied upstream-reference URL is always a pure-core reference, not a reference to the calibrated product.
    final_test = out/'test-full-final-summary.json'
    if final_test.exists():
        counts = json.loads(final_test.read_text())['summary']['counts']
        page=page.replace('<nav>', f'<p>全量回归：{counts["passed"]} 通过 · {counts["failed"]} 失败 · {counts["skipped"]} 项因环境或可选条件跳过。另行完成 72 张原生照片和 12 张颗粒候选导出。</p><nav>')
    (out/'index.html').write_text(page)
    print(json.dumps(dict(status=result['status'],rois=result['rois'],nativePNGs=len(list((out/'native').glob('*.png')))),ensure_ascii=False,indent=2))

if __name__=='__main__': main()
