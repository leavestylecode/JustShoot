"""Encode image_gen selections and arrange contact sheets; no creative image editing."""
from pathlib import Path
from io import BytesIO
import hashlib,json,shutil
import pillow_heif
from PIL import Image,ImageCms,ImageDraw,ImageFont
from setup_review import ROOT,REPORT,ART,ROWS,SRGB,sheet
pillow_heif.register_heif_opener()

def main():
 jobs=json.loads((REPORT/'jobs.json').read_text());generated={}
 for p in (REPORT/'generated').glob('*.json'):
  v=json.loads(p.read_text());generated[v['id']]=Path(v['source'])
 priorpath=REPORT/'assets.json';prior={v['id']:v for v in json.loads(priorpath.read_text())} if priorpath.exists() else {}
 records=[]
 for job in jobs:
  cid=job['id'];dest=ART/'after'/(cid+'.heic');updated=False
  if job['kind']=='reuse-approved':
   source=ROOT/'JustShoot/Resources/cards'/job['source']
   if not dest.exists() or prior.get(cid,{}).get('source')!=str(source):shutil.copy2(source,dest);updated=True
  elif cid in generated:
   source=generated[cid]
   if not dest.exists() or prior.get(cid,{}).get('source')!=str(source):
    im=Image.open(source);icc=im.info.get('icc_profile')
    if icc: im=ImageCms.profileToProfile(im,ImageCms.ImageCmsProfile(BytesIO(icc)),SRGB,outputMode='RGB')
    else:im=im.convert('RGB')
    im.resize((1024,1024),Image.Resampling.LANCZOS).save(dest,format='HEIF',quality=60,icc_profile=SRGB.tobytes());updated=True
  else:continue
  im=Image.open(dest);im.load();assert im.size==(1024,1024)
  assert 'sRGB' in ImageCms.getProfileDescription(ImageCms.ImageCmsProfile(BytesIO(im.info['icc_profile'])))
  preview=dest.with_suffix('.png')
  if updated or not preview.exists():im.convert('RGB').save(preview,icc_profile=SRGB.tobytes())
  records.append({'id':cid,'kind':job['kind'],'source':str(source),'stagedPath':str(dest),'bytes':dest.stat().st_size,'sha256':hashlib.sha256(dest.read_bytes()).hexdigest(),'dimensions':[1024,1024],'colorSpace':'sRGB'})
 (REPORT/'assets.json').write_text(json.dumps(records,indent=2)+'\n');ready={a['id'] for a in records}
 for start in range(0,len(ROWS),24):
  group=ROWS[start:start+24]
  if all(c['id'] in ready for c in group):sheet(group,ART/f'after-page-{start//24+1}.jpg','after')
 generatedrows=[c for c in ROWS if c['id'] in ready]
 for start in range(0,len(generatedrows),6):
  group=generatedrows[start:start+6];sheet(group,ART/f'review-ready-{start//6+1:02d}.jpg','after',cols=3,size=256)
 print(json.dumps({'prepared':len(records),'new':sum(a['id'] not in prior for a in records),'generated':len(generated),'bytes':sum(a['bytes'] for a in records)}))
if __name__=='__main__':main()
