"""Select a small independent batch; never regenerate an already selected new cover."""
from pathlib import Path
import json
import sys

REPORT = Path(__file__).resolve().parent
limit = int(sys.argv[1]) if len(sys.argv) > 1 else 24
assert 1 <= limit <= 24
records = {p.stem:json.loads(p.read_text()) for p in (REPORT / 'generated').glob('*.json')}
deferred = {p.stem for p in (REPORT / 'deferred').glob('*.json')}
refinements = json.loads((REPORT / 'refinement-jobs.json').read_text())
jobs = json.loads((REPORT / 'jobs.json').read_text())
pending = [j for j in refinements if records[j['id']]['source'] == j['targetSource']]
selected = pending[:1]
for j in jobs:
    if len(selected) >= limit:
        break
    if j['id'] in records or j['id'] in deferred:
        continue
    selected.append({k:j[k] for k in ['id','brand','product','prompt','references']})
if not selected:
    selected = [{k:j[k] for k in ['id','brand','product','prompt','references']} for j in jobs if j['id'] not in records][:limit]
print(json.dumps(selected, ensure_ascii=False))
