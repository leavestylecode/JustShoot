"""Build lossless comparison layouts and install only reviewed, validated encodings."""
from collections import Counter
from io import BytesIO
from pathlib import Path
import argparse
import hashlib
import json
import shutil

from PIL import Image, ImageCms, ImageDraw, ImageFont
from optimize import ROOT, REPORT, ART, CARDS, ICC, read, write, digest, image, acceptable, SAMPLES

FONT = ImageFont.truetype('/System/Library/Fonts/Supplemental/Arial Unicode.ttf', 18)
SMALL = ImageFont.truetype('/System/Library/Fonts/Supplemental/Arial Unicode.ttf', 14)
TITLE = ImageFont.truetype('/System/Library/Fonts/Supplemental/Arial Unicode.ttf', 26)
DISPLAY = {r['image']:r['brand']+' '+r['product'] for r in json.loads((ROOT/'JustShoot/Resources/cards.json').read_text())['cards']}
DISPLAY['cover_fuji_classic_neg.heic']='Fujifilm Classic Neg.'

def pairs(names, records, target, size=185, columns=3, title='BEFORE / AFTER'):
    cell_width=2*size+26
    cell_height=size+78
    count=(len(names)+columns-1)//columns
    canvas=Image.new('RGB',(columns*cell_width+20,count*cell_height+64),'#f3f1ec')
    draw=ImageDraw.Draw(canvas)
    draw.text((12,12),title,font=TITLE,fill='#222222')
    for index,name in enumerate(names):
        row=records[name]
        x,y=12+(index%columns)*cell_width,60+(index//columns)*cell_height
        draw.text((x,y),DISPLAY.get(name,name)[:48],font=SMALL,fill='#333333')
        for offset,path,label in [(0,ART/'before'/name,'压缩前'),(size+10,Path(row['path']),'压缩后')]:
            canvas.paste(image(path).resize((size,size),Image.Resampling.LANCZOS),(x+offset,y+24))
            draw.text((x+offset,y+size+30),f'{label}  {path.stat().st_size/1000:.1f} KB',font=SMALL,fill='#333333')
    canvas.save(target,icc_profile=ICC)

def review():
    rows=read('staged-assets.json')
    assert len(rows)==559
    records={r['name']:r for r in rows}
    for row in rows:
        assert digest(Path(row['path']))==row['sha256']
        assert row['bytes']<=row['beforeBytes']
        assert row['quality'] is None or acceptable(row,row['quality'])
    # Review numerical outliers plus representative typography, colors, photos and all capture covers.
    selected=[]
    groups=[sorted(rows,key=lambda r:r['ssim384'])[:15],
            sorted(rows,key=lambda r:r['footerSSIM1024'])[:15],
            sorted(rows,key=lambda r:-r['edgeMAE'])[:15],
            [records[n] for n in SAMPLES],
            [r for r in rows if r['name'].startswith('cover_')]]
    for group in groups:
        for row in group:
            if row['name'] not in selected:selected.append(row['name'])
    for start in range(0,len(selected),12):
        pairs(selected[start:start+12],records,ART/'comparisons'/f'quality-review-{start//12+1}.png',title=f'QUALITY REVIEW {start//12+1}  /  BEFORE — AFTER')
    overview=['00200_000.heic','00055_000.heic','00361_000.heic','00475_000.heic','00473_000.heic','cover_fuji_classic_neg.heic']
    pairs(overview,records,ART/'comparisons'/'compression-before-after.png',size=230,title='封面压缩前后对比 · 相同尺寸与缩放方式')
    crops=[('00361_000.heic',(210,900,820,1000)),('00055_000.heic',(700,820,1024,1024)),
           ('00475_000.heic',(30,900,560,1010)),('00541_000.heic',(180,900,850,1010)),
           ('00473_000.heic',(700,880,1024,1024)),('00200_000.heic',(680,820,1024,1024))]
    canvas=Image.new('RGB',(1180,len(crops)*280+60),'#f3f1ec');draw=ImageDraw.Draw(canvas)
    draw.text((14,12),'底部细字对比 · 相同位置与放大比例',font=TITLE,fill='#222222')
    for index,(name,box) in enumerate(crops):
        y=65+index*280
        for column,(path,label) in enumerate([(ART/'before'/name,'压缩前'),(Path(records[name]['path']),'压缩后')]):
            x=12+column*585
            draw.text((x,y),f'{label}  {name}',font=FONT,fill='#333333')
            cropped=image(path).crop(box)
            factor=min(560/cropped.width,210/cropped.height)
            cropped=cropped.resize((round(cropped.width*factor),round(cropped.height*factor)),Image.Resampling.NEAREST)
            canvas.paste(cropped,(x,y+32))
    canvas.save(ART/'comparisons'/'small-print-before-after.png',icc_profile=ICC)
    canvas.crop((0,0,1180,900)).save(ART/'comparisons'/'small-print-preview.png',icc_profile=ICC)
    summary={'count':len(rows),'beforeBytes':sum(r['beforeBytes'] for r in rows),'afterBytes':sum(r['bytes'] for r in rows),
             'qualityCounts':dict(Counter(str(r['quality']) for r in rows)),
             'ssim384Min':min(r['ssim384'] for r in rows),'footerSSIM1024Min':min(r['footerSSIM1024'] for r in rows),
             'edgeMAEMax':max(r['edgeMAE'] for r in rows),'retainedOriginals':[r['name'] for r in rows if r['quality'] is None],
             'reviewNames':selected,'reviewPages':(len(selected)+11)//12,'visualReviewComplete':False,
             'overview':str(ART/'comparisons/compression-before-after.png'),'smallPrint':str(ART/'comparisons/small-print-before-after.png')}
    write('quality-review.json',summary)
    print(json.dumps({k:v for k,v in summary.items() if k not in ('reviewNames',)},ensure_ascii=False))

def apply():
    rows=read('staged-assets.json');inventory={r['name']:r for r in read('inventory.json')}
    assert len(rows)==len(inventory)==559
    assert {r['name'] for r in rows}==set(inventory)
    review=read('quality-review.json')
    assert review['visualReviewComplete'] is True
    assert review['reviewedPages']==list(range(1,review['reviewPages']+1))
    baseline=read('baseline-hashes.json')
    for path,sha in read('master-hashes.json').items():assert digest(Path(path))==sha
    allowed={str((CARDS/r['name']).relative_to(ROOT)) for r in rows}
    assert all(digest(ROOT/path)==sha for path,sha in baseline.items() if path not in allowed)
    assert {str(p.relative_to(ROOT)) for p in (ROOT/'JustShoot').rglob('*') if p.is_file()}==set(baseline)
    # Validate the complete staged set before replacing any resources.
    for row in rows:
        staged=Path(row['path']);before=ART/'before'/row['name'];original=inventory[row['name']]
        assert digest(before)==original['sha256']
        assert digest(staged)==row['sha256'] and staged.stat().st_size==row['bytes']<=original['bytes']
        assert row['quality'] is None or acceptable(row,row['quality'])
        with Image.open(staged) as im:
            im.load();assert im.size==(1024,1024) and im.mode=='RGB'
            assert 'sRGB' in ImageCms.getProfileDescription(ImageCms.ImageCmsProfile(BytesIO(im.info['icc_profile'])))
        assert digest(CARDS/row['name']) in (original['sha256'],row['sha256'])
    for row in rows:
        destination=CARDS/row['name']
        if digest(destination)!=row['sha256']:
            temporary=destination.with_suffix('.heic.tmp')
            shutil.copy2(row['path'],temporary)
            temporary.replace(destination)
        row['installedPath']=str(destination)
        row['installedSHA256']=digest(destination)
        assert row['installedSHA256']==row['sha256']
    write('installed-assets.json',rows)
    changed={path for path,sha in baseline.items() if digest(ROOT/path)!=sha}
    expected={str((CARDS/r['name']).relative_to(ROOT)) for r in rows if r['sha256']!=inventory[r['name']]['sha256']}
    assert changed==expected
    summary={'installed':len(rows),'changedFiles':len(changed),'beforeBytes':sum(r['beforeBytes'] for r in rows),'afterBytes':sum(r['bytes'] for r in rows),
             'libraryCount':550,'captureCoverCount':9,'dimensions':[1024,1024],'ICC':'sRGB','source':'Original approved PNG masters; no generational recompression.',
             'scopeAudit':'Only cover image bytes changed. Catalog, bindings, source code, LUTs and all other app files match the starting baseline.',
             'allHashesMatched':True,'visualReview':'quality-review.json','runtimeValidationComplete':False}
    summary['savedBytes']=summary['beforeBytes']-summary['afterBytes']
    summary['savedPercent']=round(100*summary['savedBytes']/summary['beforeBytes'],2)
    write('asset-validation.json',summary)
    print(json.dumps(summary,ensure_ascii=False))

if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('command',choices=['review','apply'])
    args=parser.parse_args();{'review':review,'apply':apply}[args.command]()
