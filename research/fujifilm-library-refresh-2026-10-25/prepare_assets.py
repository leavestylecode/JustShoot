"""Encode selected image_gen results and make review sheets; no creative image edits."""
from pathlib import Path
from io import BytesIO
import hashlib
import json
import shutil

import pillow_heif
from PIL import Image, ImageCms, ImageDraw, ImageFont

pillow_heif.register_heif_opener()
ROOT = Path(__file__).resolve().parents[2]
REPORT = Path(__file__).resolve().parent
ART = Path('/Users/leavestyle/.codex/visualizations/2026/10/24/01a16dbb-b5d2-78e1-9195-24f14f709b3c/fujifilm-library-refresh-2026-10-25')
SRGB = ImageCms.ImageCmsProfile(ImageCms.createProfile('sRGB'))
FONT = ImageFont.truetype('/System/Library/Fonts/Helvetica.ttc', 15)
ROWS = json.loads((REPORT / 'inventory.json').read_text())
JOBS = json.loads((REPORT / 'jobs.json').read_text())


def sheet(rows, output, state='after', columns=6, size=186):
    margin, gap, label = 12, 12, 75
    cell = size + gap
    height = margin * 2 + ((len(rows) + columns - 1) // columns) * (size + label)
    canvas = Image.new('RGB', (margin * 2 + columns * cell - gap, height), (246, 244, 240))
    draw = ImageDraw.Draw(canvas)
    for i, row in enumerate(rows):
        x = margin + i % columns * cell
        y = margin + i // columns * (size + label)
        image = Image.open(ART / state / (row['id'] + '.png')).convert('RGB')
        canvas.paste(image.resize((size, size), Image.Resampling.LANCZOS), (x, y))
        title = row['product'].replace('Fujicolor ', '').replace('Fujichrome ', '')
        draw.text((x, y + size + 8), title[:25], font=FONT, fill=(30, 30, 30))
        draw.text((x, y + size + 29), f"{row['format']} / ISO {row['iso']}", font=FONT, fill=(60, 60, 60))
        draw.text((x, y + size + 50), row['id'], font=FONT, fill=(80, 80, 80))
    canvas.save(output, quality=94, icc_profile=SRGB.tobytes())


def main():
    generated = {}
    for batch in sorted(REPORT.glob('batch-*.json')):
        for item in json.loads(batch.read_text())['done']:
            generated[item['id']] = Path(item['source'])
    for result in sorted((REPORT / 'generated').glob('*.json')):
        item = json.loads(result.read_text())
        generated[item['id']] = Path(item['source'])
    prior_path = REPORT / 'assets.json'
    prior = {r['id']: r for r in json.loads(prior_path.read_text())} if prior_path.exists() else {}
    records = []
    for job in JOBS:
        cid = job['id']
        dest = ART / 'after' / (cid + '.heic')
        updated = False
        if job['kind'] == 'reuse-approved':
            source = ROOT / 'JustShoot/Resources/cards' / job['source']
            if not dest.exists() or prior.get(cid, {}).get('source') != str(source):
                shutil.copy2(source, dest)
                updated = True
        elif cid in generated:
            source = generated[cid]
            if not dest.exists() or prior.get(cid, {}).get('source') != str(source):
                image = Image.open(source)
                icc = image.info.get('icc_profile')
                if icc:
                    image = ImageCms.profileToProfile(image, ImageCms.ImageCmsProfile(BytesIO(icc)), SRGB, outputMode='RGB')
                else:
                    image = image.convert('RGB')
                image.resize((1024, 1024), Image.Resampling.LANCZOS).save(dest, format='HEIF', quality=60, icc_profile=SRGB.tobytes())
                updated = True
        else:
            continue
        image = Image.open(dest)
        assert image.size == (1024, 1024), (cid, image.size)
        assert 'sRGB' in ImageCms.getProfileDescription(ImageCms.ImageCmsProfile(BytesIO(image.info['icc_profile'])))
        preview = dest.with_suffix('.png')
        if updated or not preview.exists():
            image.convert('RGB').save(preview)
        records.append({'id': cid, 'kind': job['kind'], 'source': str(source), 'stagedPath': str(dest), 'bytes': dest.stat().st_size, 'sha256': hashlib.sha256(dest.read_bytes()).hexdigest(), 'dimensions': [1024, 1024], 'colorSpace': 'sRGB'})
    (REPORT / 'assets.json').write_text(json.dumps(records, indent=2) + '\n')
    ready_ids = {r['id'] for r in records}
    for batch in sorted(REPORT.glob('batch-*.json')):
        ids = {r['id'] for r in json.loads(batch.read_text())['done']}
        rows = [r for r in ROWS if r['id'] in ids]
        if rows:
            sheet(rows, ART / (batch.stem + '-after.jpg'), size=256, columns=3)
    for page in range(3):
        rows = ROWS[page * 24:(page + 1) * 24]
        if all(r['id'] in ready_ids for r in rows):
            sheet(rows, ART / f'after-page-{page + 1}.jpg')
    generate_jobs = [j for j in JOBS if j['kind'] == 'generate']
    by_id = {r['id']: r for r in ROWS}
    for start in range(0, len(generate_jobs), 6):
        rows = [by_id[j['id']] for j in generate_jobs[start:start + 6]]
        if all(r['id'] in ready_ids for r in rows):
            sheet(rows, ART / f'review-group-{start // 6 + 1:02d}.jpg', columns=3, size=256)
    print(json.dumps({'prepared': len(records), 'generated': len(generated), 'bytes': sum(r['bytes'] for r in records)}))


if __name__ == '__main__':
    main()
