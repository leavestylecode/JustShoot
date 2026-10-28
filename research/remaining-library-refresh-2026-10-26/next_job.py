"""Select one unfinished generation, preserving all saved selections."""
from pathlib import Path
import json
import sys

REPORT = Path(__file__).resolve().parent
jobs = json.loads((REPORT / 'jobs.json').read_text())
records = {p.stem: json.loads(p.read_text()) for p in (REPORT / 'generated').glob('*.json')}
assert all(Path(x['source']).is_file() for x in records.values())
deferred = {p.stem for p in (REPORT / 'deferred').glob('*.json')}
retry_skip_path = REPORT / 'retry-sweep-skipped.json'
retry_skipped = set(json.loads(retry_skip_path.read_text())) if retry_skip_path.exists() else set()
refinements = json.loads((REPORT / 'refinement-jobs.json').read_text())
refined = {key for key, value in records.items() if value.get('kind') == 'refinement'}
pending_refinements = [x for x in refinements if x['id'] not in refined]
assets = json.loads((REPORT / 'assets.json').read_text()) if (REPORT / 'assets.json').exists() else []
installed = sum(x.get('status') == 'reviewed-installed' and x['source'] == records.get(x['id'],{}).get('source') for x in assets)
approvals = json.loads((REPORT / 'approved-sources.json').read_text()) if (REPORT / 'approved-sources.json').exists() else []
approved = sum(x['source'] == records.get(x['id'],{}).get('source') for x in approvals)
progress = {'requested': len(jobs), 'generated': len(records), 'remaining': len(jobs)-len(records),
            'refinementsRequested': len(refinements), 'refinementsGenerated': len(refined.intersection(x['id'] for x in refinements)),
            'additionalRefinements': sorted(refined.difference(x['id'] for x in refinements)),
            'refinementPending': [x['id'] for x in pending_refinements],
            'deferred': sorted(x for x in deferred if x not in records or x in {j['id'] for j in pending_refinements}),
            'retrySweepSkipped': sorted(retry_skipped),
            'approved': approved, 'remainingToApprove':len(jobs)-approved,
            'installed': installed, 'complete': False}
(REPORT / 'progress.json').write_text(json.dumps(progress, indent=2)+'\n')
mode = sys.argv[1] if len(sys.argv)>1 else 'auto'
candidate = None
if mode in ('auto', 'refine'):
    candidate = next((x for x in pending_refinements if x['id'] not in deferred), None)
if candidate is None and mode in ('auto', 'new'):
    candidate = next((x for x in jobs if x['id'] not in records and x['id'] not in deferred), None)
if candidate is None and mode == 'retry':
    candidate = next((x for x in pending_refinements if x['id'] in deferred and x['id'] not in retry_skipped), None)
    if candidate is None:
        candidate = next((x for x in jobs if x['id'] not in records and x['id'] not in retry_skipped), None)
if candidate:
    candidate = {k: candidate[k] for k in ['id','brand','product','prompt','references','kind','targetSource','correction'] if k in candidate}
    candidate['sourceCountBefore'] = len(records)
print(json.dumps(candidate, ensure_ascii=False))
