"""Arrange a generated candidate and its real packaging for inspection only."""
from pathlib import Path
import sys
from PIL import Image,ImageDraw,ImageFont

source, reference, destination = map(Path, sys.argv[1:4])
canvas = Image.new('RGB',(792,420),(246,244,240))
draw = ImageDraw.Draw(canvas)
font = ImageFont.truetype('/System/Library/Fonts/Helvetica.ttc',14)
for n,(path,label) in enumerate([(source,'NEW COVER'),(reference,'REAL PACKAGING REFERENCE')]):
    x=8+n*392
    draw.text((x,6),label,font=font,fill=(50,50,50))
    im=Image.open(path).convert('RGB')
    im.thumbnail((384,384),Image.Resampling.LANCZOS)
    canvas.paste(im,(x+(384-im.width)//2,28+(384-im.height)//2))
destination.parent.mkdir(parents=True,exist_ok=True)
canvas.save(destination,quality=85)
