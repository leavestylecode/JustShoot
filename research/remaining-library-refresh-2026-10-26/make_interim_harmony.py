"""Arrange installed covers for review; never modify creative assets."""
import json
import sys
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont
import pillow_heif

pillow_heif.register_heif_opener()
ROOT = Path(__file__).resolve().parents[2]
REPORT = Path(__file__).resolve().parent
ART = Path('/Users/leavestyle/.codex/visualizations/2026/10/24/01a16dbb-b5d2-78e1-9195-24f14f709b3c/remaining-library-refresh-2026-10-26')
rows = json.loads((ROOT / 'JustShoot/Resources/cards.json').read_text())['cards']
by_id = {c['id']: c for c in rows}
installation = json.loads((REPORT / 'interim-installation.json').read_text())
fixed = [c['id'] for brand in ('Kodak', 'Fujifilm') for c in [r for r in rows if r['brand'] == brand][:3]]
selected = fixed + installation['installedNow']
count = installation['installed']
recent = int(sys.argv[1]) if len(sys.argv) > 1 else None
if recent:
    assets = json.loads((REPORT / 'assets.json').read_text())
    installed_ids = sorted(a['id'] for a in assets if a.get('status') == 'reviewed-installed')
    selected = fixed + installed_ids[-recent:]
out = Image.new('RGB', (960, ((len(selected) + 5) // 6) * 196), (243, 242, 238))
draw = ImageDraw.Draw(out)
font = ImageFont.truetype('/System/Library/Fonts/Helvetica.ttc', 11)
for index, cid in enumerate(selected):
    card = by_id[cid]
    x, y = (index % 6) * 160 + 8, (index // 6) * 196 + 8
    with Image.open(ROOT / 'JustShoot/Resources/cards' / card['image']) as image:
        thumb = image.convert('RGB').resize((144, 144), Image.Resampling.LANCZOS)
    out.paste(thumb, (x, y))
    draw.text((x, y + 149), card['brand'][:23], font=font, fill='black')
    draw.text((x, y + 164), card['product'][:23], font=font, fill='black')
suffix = f'-recent-{recent}' if recent else ''
path = ART / f'interim-harmony-{count}{suffix}.jpg'
out.save(path, quality=89)
(REPORT / f'interim-harmony-{count}{suffix}.json').write_text(json.dumps({'ids': selected, 'installedCount': count, 'recent': recent, 'complete': False}, indent=2) + '\n')
print(path)
