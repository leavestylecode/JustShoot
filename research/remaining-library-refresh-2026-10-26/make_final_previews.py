"""Arrange existing finished images for review; does not create or edit cover art."""
import json
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont, ImageCms
import pillow_heif

pillow_heif.register_heif_opener()
REPORT = Path(__file__).resolve().parent
ROOT = REPORT.parents[1]
ART = Path('/Users/leavestyle/.codex/visualizations/2026/10/24/01a16dbb-b5d2-78e1-9195-24f14f709b3c/remaining-library-refresh-2026-10-26')
ROWS = {c['id']: c for c in json.loads((ROOT / 'JustShoot/Resources/cards.json').read_text())['cards']}
FONT = ImageFont.truetype('/System/Library/Fonts/Helvetica.ttc', 14)
TITLE = ImageFont.truetype('/System/Library/Fonts/Helvetica.ttc', 24)
ICC = ImageCms.ImageCmsProfile(ImageCms.createProfile('sRGB')).tobytes()

def thumb(path, size):
    with Image.open(path) as image:
        return image.convert('RGB').resize((size, size), Image.Resampling.LANCZOS)

def resource(cid):
    return ROOT / 'JustShoot/Resources/cards' / ROWS[cid]['image']

# Six previously approved Kodak/Fujifilm covers among 18 newly completed covers.
mixed = ['00200_000', '00361_000', '00473_000', '00023_000', '00478_000', '00463_000',
         '00419_000', '00021_000', '00367_000', '00517_000', '00055_000', '00475_000',
         '00476_000', '00535_000', '00081_000', '00471_000', '00541_000', '00558_000',
         '00506_000', '00451_000', '00438_000', '00544_000', '00455_000', '00560_000']
canvas = Image.new('RGB', (1200, 1040), (244, 242, 237))
draw = ImageDraw.Draw(canvas)
draw.text((18, 16), 'FINAL LIBRARY  /  PACKAGING IDENTITIES, ONE COLLECTION', font=TITLE, fill=(34, 33, 30))
for i, cid in enumerate(mixed):
    x, y = 12 + (i % 6) * 198, 64 + (i // 6) * 242
    canvas.paste(thumb(resource(cid), 180), (x, y))
    draw.text((x, y + 186), ROWS[cid]['brand'], font=FONT, fill=(40, 40, 37))
    draw.text((x, y + 205), ROWS[cid]['product'][:25], font=FONT, fill=(75, 73, 67))
canvas.save(ART / 'final-harmony.jpg', quality=93, icc_profile=ICC)

comparison = ['00361_000', '00473_000', '00475_000', '00463_000', '00478_000', '00419_000', '00517_000', '00541_000']
canvas = Image.new('RGB', (1248, 530), (244, 242, 237))
draw = ImageDraw.Draw(canvas)
draw.text((18, 16), 'BEFORE / AFTER  —  FINAL INSTALLED COVERS', font=TITLE, fill=(34, 33, 30))
for i, cid in enumerate(comparison):
    x, y = 12 + (i % 4) * 310, 62 + (i // 4) * 235
    draw.text((x, y), ROWS[cid]['brand'] + ' / ' + ROWS[cid]['product'][:23], font=FONT, fill=(40, 40, 37))
    for offset, label, path in [(0, 'BEFORE', ART / 'before' / (cid + '.heic')), (150, 'AFTER', resource(cid))]:
        canvas.paste(thumb(path, 144), (x + offset, y + 30))
        draw.text((x + offset, y + 181), label, font=FONT, fill=(75, 73, 67))
canvas.save(ART / 'final-before-after.jpg', quality=94, icc_profile=ICC)
(REPORT / 'final-previews.json').write_text(json.dumps({'mixedIds': mixed, 'beforeAfterIds': comparison, 'mixedImage': str(ART / 'final-harmony.jpg'), 'comparisonImage': str(ART / 'final-before-after.jpg'), 'reviewed': False}, indent=2) + '\n')
print(ART / 'final-harmony.jpg')
print(ART / 'final-before-after.jpg')
