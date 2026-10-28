"""Re-encode approved cover masters; preserve artwork, dimensions and color space."""
from concurrent.futures import ThreadPoolExecutor, as_completed
from io import BytesIO
from pathlib import Path
import argparse
import fcntl
import hashlib
import json
import shutil
import time

import numpy as np
import pillow_heif
from PIL import Image, ImageCms, ImageDraw, ImageFont

pillow_heif.register_heif_opener()
ROOT = Path(__file__).resolve().parents[2]
REPORT = Path(__file__).resolve().parent
ART = Path('/Users/leavestyle/.codex/visualizations/2026/10/27/justshoot-cover-compression')
CARDS = ROOT / 'JustShoot/Resources/cards'
ICC = ImageCms.ImageCmsProfile(ImageCms.createProfile('sRGB')).tobytes()
FONT = ImageFont.truetype('/System/Library/Fonts/Helvetica.ttc', 17)
SMALL = ImageFont.truetype('/System/Library/Fonts/Helvetica.ttc', 14)
PARAMS = {'preset': 'slower', 'x265:pools': '2', 'x265:frame-threads': '1'}
SAMPLES = ['00361_000.heic', '00475_000.heic', '00558_000.heic', 'cover_fuji_classic_neg.heic',
           '00541_000.heic', '00473_000.heic', '00055_000.heic', '00463_000.heic',
           '00517_000.heic', '00200_000.heic', '00081_000.heic', '00057_000.heic']

def read(name):
    return json.loads((REPORT / name).read_text())

def write(name, value):
    target = REPORT / name
    temporary = target.with_suffix(target.suffix + '.tmp')
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')
    temporary.replace(target)

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def image(path):
    with Image.open(path) as source:
        return source.convert('RGB')

def master(record):
    with Image.open(record['source']) as source:
        icc = source.info.get('icc_profile')
        if icc:
            result = ImageCms.profileToProfile(source, ImageCms.ImageCmsProfile(BytesIO(icc)), ImageCms.ImageCmsProfile(BytesIO(ICC)), outputMode='RGB')
        else:
            result = source.convert('RGB')
    return result.resize((1024, 1024), Image.Resampling.LANCZOS)

def luma(value):
    return np.asarray(value, dtype=np.float32) @ np.array([0.2126, 0.7152, 0.0722], dtype=np.float32)

def box_mean(value, width=7):
    # Uniform valid window; this metric is named explicitly in the report.
    integral = np.pad(value, ((1, 0), (1, 0))).cumsum(0, dtype=np.float64).cumsum(1)
    return (integral[width:, width:] - integral[:-width, width:] - integral[width:, :-width] + integral[:-width, :-width]) / width**2

def ssim(first, second):
    x, y = luma(first), luma(second)
    mx, my = box_mean(x), box_mean(y)
    vx = np.maximum(box_mean(x*x) - mx*mx, 0)
    vy = np.maximum(box_mean(y*y) - my*my, 0)
    cov = box_mean(x*y) - mx*my
    result = ((2*mx*my + 6.5025) * (2*cov + 58.5225)) / ((mx*mx + my*my + 6.5025) * (vx + vy + 58.5225))
    return float(np.mean(result))

def metrics(before, after):
    x, y = luma(before), luma(after)
    gx, gy = np.zeros_like(x), np.zeros_like(x)
    gx[:, 1:] = np.abs(np.diff(x, axis=1))
    gy[1:, :] = np.abs(np.diff(x, axis=0))
    edge = np.maximum(gx, gy) > 35
    errors = np.abs(np.asarray(before, dtype=np.float32) - np.asarray(after, dtype=np.float32))
    return {'ssim384': round(ssim(before.resize((384,384), Image.Resampling.LANCZOS), after.resize((384,384), Image.Resampling.LANCZOS)), 6),
            'ssim1024': round(ssim(before, after), 6),
            'footerSSIM1024': round(ssim(before.crop((0, 800, 1024, 1024)), after.crop((0, 800, 1024, 1024))), 6),
            'edgeMAE': round(float(errors[edge].mean()), 4) if edge.any() else 0,
            'rgbMAE': round(float(errors.mean()), 4)}

def encode(record, quality, folder='candidates'):
    target = ART / folder / (record['name'] if folder == 'after' else f"{Path(record['name']).stem}-q{quality}.heic")
    if target.is_file():
        try:
            with Image.open(target) as existing:
                existing.load()
                assert existing.size == (1024,1024)
        except (OSError, ValueError, AssertionError):
            target.unlink()
    if not target.is_file():
        source = master(record)
        temporary = target.with_suffix('.heic.tmp')
        source.save(temporary, format='HEIF', quality=quality, chroma=420, enc_params=dict(PARAMS), icc_profile=ICC, exif=None, xmp=None)
        temporary.replace(target)
    before = image(ART / 'before' / record['name'])
    after = image(target)
    assert after.size == before.size == (1024,1024)
    return {'name': record['name'], 'quality': quality, 'beforeBytes': record['bytes'], 'bytes': target.stat().st_size, 'path': str(target), 'sha256': digest(target), **metrics(before, after)}

def backup():
    inventory = read('inventory.json')
    for record in inventory:
        target = ART / 'before' / record['name']
        if not target.exists():
            assert digest(CARDS / record['name']) == record['sha256']
            shutil.copy2(CARDS / record['name'], target)
        assert digest(target) == record['sha256']
    print(json.dumps({'backedUp': len(inventory), 'bytes': sum(r['bytes'] for r in inventory)}), flush=True)

def calibrate():
    inventory = {r['name']: r for r in read('inventory.json')}
    jobs = [(inventory[name], q) for name in SAMPLES for q in (40,45,50,55)]
    results = []
    with ThreadPoolExecutor(max_workers=3) as pool:
        pending = {pool.submit(encode, r, q): (r['name'], q) for r,q in jobs}
        for future in as_completed(pending):
            result = future.result()
            results.append(result)
    results.sort(key=lambda r: (SAMPLES.index(r['name']), r['quality']))
    write('calibration.json', results)
    for q in (40,45,50,55):
        group = [r for r in results if r['quality']==q]
        print(json.dumps({'quality':q,'bytes':sum(r['bytes'] for r in group),'beforeBytes':sum(r['beforeBytes'] for r in group),'ssim384Min':min(r['ssim384'] for r in group),'footerMin':min(r['footerSSIM1024'] for r in group),'maxEdgeMAE':max(r['edgeMAE'] for r in group)}), flush=True)
    for start in range(0,len(SAMPLES),3):
        rows = SAMPLES[start:start+3]
        canvas = Image.new('RGB', (1450, len(rows)*345+50), '#efeee9')
        draw = ImageDraw.Draw(canvas)
        for column, label in enumerate(['CURRENT', 'Q40', 'Q45', 'Q50', 'Q55']):
            draw.text((column*288+15,12), label, font=FONT, fill='black')
        for row,name in enumerate(rows):
            paths = [ART/'before'/name] + [ART/'candidates'/f'{Path(name).stem}-q{q}.heic' for q in (40,45,50,55)]
            for column,path in enumerate(paths):
                x,y=column*288+10,row*345+45
                canvas.paste(image(path).resize((272,272),Image.Resampling.LANCZOS),(x,y))
                draw.text((x,y+277),name[:30],font=SMALL,fill='black')
                draw.text((x,y+298),f'{path.stat().st_size/1000:.1f} KB',font=SMALL,fill='black')
        canvas.save(ART/'comparisons'/f'calibration-{start//3+1}.png',icc_profile=ICC)

def acceptable(result, quality):
    if quality == 45:
        return result['ssim384'] >= 0.993 and result['footerSSIM1024'] >= 0.98 and result['edgeMAE'] <= 3.8
    return result['ssim384'] >= 0.992 and result['footerSSIM1024'] >= 0.96 and result['edgeMAE'] <= 4.0

def optimize_one(record):
    attempts=[]
    for quality in (45,50,55,58):
        result=encode(record,quality)
        attempts.append({k:v for k,v in result.items() if k not in ('path','sha256')})
        if result['bytes'] >= record['bytes']:
            break
        if acceptable(result, quality):
            target=ART/'after'/record['name']
            shutil.copy2(result['path'],target)
            return record | result | {'path':str(target),'attempts':attempts,'decision':'re-encoded from original master'}
    target=ART/'after'/record['name']
    shutil.copy2(ART/'before'/record['name'],target)
    return record | {'quality':None,'beforeBytes':record['bytes'],'path':str(target),'attempts':attempts,'decision':'original retained; no smaller candidate passed quality gates','ssim384':1.0,'ssim1024':1.0,'footerSSIM1024':1.0,'edgeMAE':0.0,'rgbMAE':0.0}

def optimize_all():
    inventory=read('inventory.json')
    lock = (REPORT / 'encoding.lock').open('w')
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    previous = read('staged-assets.json') if (REPORT / 'staged-assets.json').exists() else []
    results = [r for r in previous if Path(r['path']).is_file() and digest(Path(r['path'])) == r['sha256']]
    completed = {r['name'] for r in results}
    print(json.dumps({'resuming':len(completed),'remaining':len(inventory)-len(completed)}),flush=True)
    started=time.monotonic()
    with ThreadPoolExecutor(max_workers=3) as pool:
        pending={pool.submit(optimize_one,record):record['name'] for record in inventory if record['name'] not in completed}
        for future in as_completed(pending):
            results.append(future.result())
            if len(results)%25==0 or len(results)==len(inventory):
                write('staged-assets.json',sorted(results,key=lambda r:r['name']))
                print(json.dumps({'prepared':len(results),'total':len(inventory),'beforeBytes':sum(r['beforeBytes'] for r in results),'afterBytes':sum(r['bytes'] for r in results),'elapsedSeconds':round(time.monotonic()-started,1)}),flush=True)
    write('staged-assets.json',sorted(results,key=lambda r:r['name']))
    fcntl.flock(lock, fcntl.LOCK_UN)
    lock.close()

if __name__ == '__main__':
    parser=argparse.ArgumentParser()
    parser.add_argument('command',choices=['backup','calibrate','optimize'])
    args=parser.parse_args()
    {'backup':backup,'calibrate':calibrate,'optimize':optimize_all}[args.command]()
