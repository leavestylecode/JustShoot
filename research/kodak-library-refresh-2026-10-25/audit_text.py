"""Read-only OCR and heuristic flags to guide human visual review, never auto-edit assets."""
import json,re,subprocess
from pathlib import Path
from setup_review import REPORT,ART,ROWS

def norm(s):return re.sub(r'[^A-Z0-9]','',s.upper())
files=sorted((ART/'after').glob('*.png'))
assert len(files)==147,len(files)
with (REPORT/'ocr.json').open('w') as f:
 r=subprocess.run(['swift',str(REPORT/'recognize_text.swift'),*[str(p) for p in files]],stdout=f,stderr=subprocess.PIPE,text=True,check=True)
records=json.loads((REPORT/'ocr.json').read_text());rows={c['id']:c for c in ROWS};flags=[]
for record in records:
 cid=Path(record['path']).stem;c=rows[cid];lines=record.get('text',[]);text=' '.join(lines);full=norm(text)
 reasons=[]
 if 'error' in record:reasons.append(record['error'])
 if not norm(c['product']) in full:reasons.append('Exact catalog title not contiguous in OCR; visually inspect era-specific/reordered lettering.')
 for token in ['EXTAR','EXTACHROME','UNKNOWN','JUSTSHOOT','SRGB']:
  if token in full:reasons.append('Unexpected token '+token)
 for line in record.get('observations',[]):
  if norm(line['text']).startswith(norm(c['format'])) and line['height']>.048 and c['product']!='110 Film':reasons.append('Possible oversized format: '+line['text'])
 if reasons:flags.append({'id':cid,'product':c['product'],'reasons':reasons,'text':lines})
(REPORT/'ocr-review-flags.json').write_text(json.dumps(flags,ensure_ascii=False,indent=2)+'\n')
print(json.dumps({'recognized':len(records),'flaggedForVisualReview':len(flags),'ids':[f['id'] for f in flags]}))
