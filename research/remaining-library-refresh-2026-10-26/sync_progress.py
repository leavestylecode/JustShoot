"""Persist selected image_gen output paths and resumable per-cover progress."""
import json
from pathlib import Path

REPORT = Path(__file__).resolve().parent

def main():
    jobs = json.loads((REPORT / 'jobs.json').read_text())
    generated = {p.stem: json.loads(p.read_text()) for p in (REPORT / 'generated').glob('*.json')}
    errors = {p.stem.removeprefix('generated-error-'): json.loads(p.read_text()) for p in REPORT.glob('generated-error-*.json')}
    for job in jobs:
        cid = job['id']
        if cid in generated:
            source = Path(generated[cid]['source'])
            assert source.exists(), source
            job.update(status='generated-awaiting-review', selectedSource=str(source), generationMode='builtin image_gen')
        elif cid in errors:
            job.update(status='retry-needed', lastError=errors[cid]['error'])
    (REPORT / 'jobs.json').write_text(json.dumps(jobs, ensure_ascii=False, indent=2) + '\n')
    progress = {'requested':len(jobs), 'generated':len(generated), 'remaining':len(jobs)-len(generated), 'retryNeeded':[j['id'] for j in jobs if j['id'] not in generated and j['id'] in errors], 'installed':0, 'complete':False}
    (REPORT / 'progress.json').write_text(json.dumps(progress, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps(progress, ensure_ascii=False))

if __name__ == '__main__': main()
