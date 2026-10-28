"""Inventory, back up, and arrange existing assets and packaging scans for visual review."""
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor, as_completed
from io import BytesIO
import hashlib,json,shutil,urllib.request,subprocess
import pillow_heif
from PIL import Image,ImageCms,ImageDraw,ImageFont
pillow_heif.register_heif_opener()
ROOT=Path(__file__).resolve().parents[2]
REPORT=Path(__file__).resolve().parent
ART=Path('/Users/leavestyle/.codex/visualizations/2026/10/24/01a16dbb-b5d2-78e1-9195-24f14f709b3c/remaining-library-refresh-2026-10-26')
SRGB=ImageCms.ImageCmsProfile(ImageCms.createProfile('sRGB'))
FONT=ImageFont.truetype('/System/Library/Fonts/Helvetica.ttc',15)
for s in ['before','after','references','styles']: (ART/s).mkdir(parents=True,exist_ok=True)
(REPORT/'generated').mkdir(exist_ok=True)
CAT=ROOT/'JustShoot/Resources/cards.json'
if not (REPORT/'cards-before.json').exists():
 shutil.copy2(CAT,REPORT/'cards-before.json')
 baseline={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in (ROOT/'JustShoot').rglob('*') if p.is_file()}
 (REPORT/'baseline-hashes.json').write_text(json.dumps(baseline,indent=2)+'\n')
ROWS=[c for c in json.loads((REPORT/'cards-before.json').read_text())['cards'] if c['brand'] not in ('Kodak','Fujifilm')]
(REPORT/'inventory.json').write_text(json.dumps(ROWS,ensure_ascii=False,indent=2)+'\n')

def png(path,dest):
 im=Image.open(path);icc=im.info.get('icc_profile')
 if icc: im=ImageCms.profileToProfile(im,ImageCms.ImageCmsProfile(BytesIO(icc)),SRGB,outputMode='RGB')
 else: im=im.convert('RGB')
 im.save(dest,icc_profile=SRGB.tobytes())

def sheet(rows,output,state='before',cols=6,size=186,label=75):
 gap=12;canvas=Image.new('RGB',(24+cols*(size+gap)-gap,24+((len(rows)+cols-1)//cols)*(size+label)),(246,244,240));draw=ImageDraw.Draw(canvas)
 for i,c in enumerate(rows):
  x=12+(i%cols)*(size+gap);y=12+(i//cols)*(size+label)
  p=ART/state/(c['id']+('.jpg' if state=='references' else '.png'));im=Image.open(p).convert('RGB');im.thumbnail((size,size),Image.Resampling.LANCZOS)
  canvas.paste(im,(x+(size-im.width)//2,y+(size-im.height)//2))
  draw.text((x,y+size+5),c['product'][:25],font=FONT,fill=(25,25,25));draw.text((x,y+size+27),f"{c['format']} / {c['quantity']}",font=FONT,fill=(55,55,55));draw.text((x,y+size+49),c['id'],font=FONT,fill=(70,70,70))
 canvas.save(output,quality=94,icc_profile=SRGB.tobytes())

if __name__=='__main__':
 for c in ROWS:
  dest=ART/'before'/c['image']
  if not dest.exists():shutil.copy2(ROOT/'JustShoot/Resources/cards'/c['image'],dest)
  if not dest.with_suffix('.png').exists():png(dest,dest.with_suffix('.png'))
 for name in ['cover_kodak_portra_400','cover_fuji_velvia','cover_fuji_provia_100f','cover_fuji_classic_chrome']:
  png(ROOT/'JustShoot/Resources/cards'/(name+'.heic'),ART/'styles'/(name+'.png'))
 def download(c):
  url='https://raw.githubusercontent.com/dekuNukem/Film-Packaging/master/film_packaging/lowres/'+c['id']+'.jpg';dest=ART/'references'/(c['id']+'.jpg')
  if not dest.exists():
   subprocess.run(['curl','-fsSL','--retry','3','--retry-all-errors','--connect-timeout','10','--max-time','35',url,'-o',str(dest)],check=True,capture_output=True)
  im=Image.open(dest);im.load()
  return {'id':c['id'],'url':url,'path':str(dest),'sha256':hashlib.sha256(dest.read_bytes()).hexdigest()}
 refs=[]
 with ThreadPoolExecutor(max_workers=6) as pool:
  for f in as_completed([pool.submit(download,c) for c in ROWS]):refs.append(f.result())
 tree=json.loads(Path('/tmp/justshoot-film-packaging-tree.json').read_text())
 (REPORT/'packaging-references.json').write_text(json.dumps({'archive':'https://github.com/dekuNukem/Film-Packaging','treeSHA':tree.get('sha'),'images':sorted(refs,key=lambda r:r['id'])},indent=2)+'\n')
 for i in range(0,len(ROWS),24):
  sheet(ROWS[i:i+24],ART/f'before-page-{i//24+1}.jpg')
  sheet(ROWS[i:i+24],ART/f'packaging-page-{i//24+1}.jpg',state='references',size=230,cols=6)
 print(json.dumps({'cards':len(ROWS),'references':len(refs),'art':str(ART)}))
