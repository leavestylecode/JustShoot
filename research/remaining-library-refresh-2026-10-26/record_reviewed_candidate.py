"""Record an explicitly verified native-output candidate; never infer its identity."""
from pathlib import Path
import hashlib
import json
import sys
from PIL import Image

REPORT = Path(__file__).resolve().parent
cid, note = sys.argv[1:3]
watch = json.loads((REPORT / 'latest-native-watch.json').read_text())
job = watch['job']
assert cid == job['id'] and len(watch['candidates']) == 1
source = Path(watch['candidates'][0])
assert source.is_file() and source.suffix == '.png'
with Image.open(source) as im:
    im.verify()
record = {'id':cid, 'source':str(source), 'status':'reviewed-source-awaiting-encoding',
          'generationPrompt':job['prompt'], 'references':job['references'],
          'provenance':{'mode':'built-in image_gen', 'selection':'native output visually verified',
                        'toolResultConfirmed':watch['confirmed'], 'review':note}}
if job.get('kind') == 'refinement':
    record.update(kind='refinement', previousSource=job['targetSource'],
                  correction=job['correction'], refinementPrompt=job['prompt'])
(REPORT / 'generated' / f'{cid}.json').write_text(json.dumps(record,ensure_ascii=False,indent=2)+'\n')
archive = REPORT / 'native-watch-results'
archive.mkdir(exist_ok=True)
(archive / f'{cid}-{source.stem}.json').write_text(json.dumps(watch,ensure_ascii=False,indent=2)+'\n')
approvals = json.loads((REPORT / 'approved-sources.json').read_text())
approvals = [a for a in approvals if a['id'] != cid]
approvals.append({'id':cid, 'source':str(source), 'sourceSHA256':hashlib.sha256(source.read_bytes()).hexdigest(), 'review':note})
(REPORT / 'approved-sources.json').write_text(json.dumps(sorted(approvals,key=lambda x:x['id']),ensure_ascii=False,indent=2)+'\n')
review = json.loads((REPORT / 'review-notes.json').read_text())
review.update(approvedSourceCount=len(approvals), complete=False)
review['pendingCorrections']=[x for x in review.get('pendingCorrections',[]) if x != cid]
if job.get('kind') == 'refinement':
    review['refinementsResolved']=[x for x in review.get('refinementsResolved',[]) if x['id'] != cid]+[{'id':cid,'source':str(source)}]
(REPORT / 'review-notes.json').write_text(json.dumps(review,ensure_ascii=False,indent=2)+'\n')
print(json.dumps({'recorded':cid,'reviewedSourceCount':len(approvals)}))
