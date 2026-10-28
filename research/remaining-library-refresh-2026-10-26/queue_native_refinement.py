"""Save one explicitly requested refinement of a reviewed but unapproved candidate."""
from pathlib import Path
import json

REPORT=Path(__file__).resolve().parent
value=json.loads((REPORT/'latest-queued-refinement.json').read_text())
job,watch=value['job'],value['watch']
cid=job['id']
assert watch['job']['id']==cid and watch['candidates']==[job['targetSource']]
record={'id':cid,'source':job['targetSource'],'status':'needs-refinement',
        'generationPrompt':watch['job']['prompt'],'references':watch['job']['references'],
        'refinementReason':job['correction']}
(REPORT/'generated'/f'{cid}.json').write_text(json.dumps(record,ensure_ascii=False,indent=2)+'\n')
jobs=json.loads((REPORT/'refinement-jobs.json').read_text())
jobs=[x for x in jobs if x['id']!=cid]+[job]
(REPORT/'refinement-jobs.json').write_text(json.dumps(jobs,ensure_ascii=False,indent=2)+'\n')
review=json.loads((REPORT/'review-notes.json').read_text())
review['pendingCorrections']=sorted(set(review.get('pendingCorrections',[]))|{cid})
(REPORT/'review-notes.json').write_text(json.dumps(review,ensure_ascii=False,indent=2)+'\n')
archive=REPORT/'unapproved-native-sources';archive.mkdir(exist_ok=True)
(archive/f'{cid}.json').write_text(json.dumps(value,ensure_ascii=False,indent=2)+'\n')
print(json.dumps({'queued':cid,'correction':job['correction']}))
