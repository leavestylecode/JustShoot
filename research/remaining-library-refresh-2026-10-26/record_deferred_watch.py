"""Preserve a failed native-tool attempt without changing any app resource."""
from pathlib import Path
import json
import shutil
import time

report = Path(__file__).resolve().parent
record = json.loads((report / 'latest-timeout.json').read_text())
assert not record.get('candidates'), 'Review returned candidates before deferring'
cid = record['job']['id']
destination = report / 'deferred' / f'{cid}.json'
stamp = str(time.time_ns())
if destination.exists():
    shutil.copy2(destination, report / 'timed-out-attempts' / f'{cid}-before-{stamp}.json')
destination.write_text(json.dumps(record, ensure_ascii=False, indent=2) + '\n')
skip = report / 'retry-sweep-skipped.json'
skipped = json.loads(skip.read_text()) if skip.exists() else []
skip.write_text(json.dumps(list(dict.fromkeys(skipped + [cid])), indent=2) + '\n')
print(json.dumps({'deferred': cid, 'resourceUnchanged': True}))
