"""Arrange exported assets for review, without editing the cover designs."""
import json
from pathlib import Path
from PIL import Image,ImageDraw,ImageFont
from setup_review import ROOT,REPORT,ART,ROWS,SRGB,sheet
IDS=['00021_000','00079_000','00081_000','00091_000','00200_000','00345_000','00501_000','00155_000','00104_000','00028_000','00519_000','00459_000']
by_id={c['id']:c for c in ROWS}
rows=[by_id[cid] for cid in IDS]
for state in ['before','after']:
 sheet(rows,ART/f'representative-{state}.jpg',state,cols=4,size=224)
old=Image.open(ART/'representative-before.jpg');new=Image.open(ART/'representative-after.jpg')
font=ImageFont.truetype('/System/Library/Fonts/Helvetica.ttc',27)
canvas=Image.new('RGB',(old.width,old.height+new.height+130),(246,244,240));draw=ImageDraw.Draw(canvas)
draw.text((14,15),'BEFORE',font=font,fill=(30,30,30));canvas.paste(old,(0,55));draw.text((14,old.height+75),'AFTER',font=font,fill=(30,30,30));canvas.paste(new,(0,old.height+130));canvas.save(ART/'representative-before-after.jpg',quality=94,icc_profile=SRGB.tobytes())
# A110px grid tests the same small-print balance as the in-app cards.
sheet(rows,ART/'representative-110px.jpg','after',cols=4,size=110,label=75)
# Interleave12 Kodak and12 already-approved Fuji covers for whole-library harmony review.
fuji_dir=ART.parent/'fujifilm-library-refresh-2026-10-25';fj=json.loads((ROOT/'research/fujifilm-library-refresh-2026-10-25/inventory.json').read_text());fjby={c['id']:c for c in fj}
fids=['00007_000','00022_000','00044_000','00055_000','00087_000','00139_000','00202_000','00229_000','00248_000','00341_000','00524_000','00556_000']
size=180;gap=12;label=50;cols=6;can=Image.new('RGB',(24+cols*(size+gap)-gap,24+4*(size+label)),(246,244,240));dr=ImageDraw.Draw(can);f=ImageFont.truetype('/System/Library/Fonts/Helvetica.ttc',14)
mix=[]
for k,fid in zip(rows,fids):mix.extend([(k,ART/'after'/(k['id']+'.png')),(fjby[fid],fuji_dir/'after'/(fid+'.png'))])
for i,(c,p) in enumerate(mix):
 x=12+(i%cols)*(size+gap);y=12+(i//cols)*(size+label);im=Image.open(p).convert('RGB').resize((size,size),Image.Resampling.LANCZOS);can.paste(im,(x,y));dr.text((x,y+size+6),c['brand'],font=f,fill=(40,40,40));dr.text((x,y+size+26),c['product'][:25],font=f,fill=(40,40,40))
can.save(ART/'kodak-fuji-harmony.jpg',quality=94,icc_profile=SRGB.tobytes())
print('comparison and harmony sheets saved')
