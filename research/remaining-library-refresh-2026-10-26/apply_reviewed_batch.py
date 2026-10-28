"""Install only individually reviewed sources; the 331-cover task stays incomplete."""
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil

ROOT = Path(__file__).resolve().parents[2]
REPORT = Path(__file__).resolve().parent
CATALOG = ROOT / 'JustShoot/Resources/cards.json'

def read(path):
    return json.loads(path.read_text())

def write(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def main():
    before = read(REPORT / 'cards-before.json')
    current = read(CATALOG)
    assert len(current['cards']) == len(before['cards']) == 550
    assert {k:v for k,v in current.items() if k != 'cards'} == {k:v for k,v in before.items() if k != 'cards'}
    rows = {c['id']:c for c in current['cards']}
    target = {c['id'] for c in before['cards'] if c['brand'] not in ('Kodak', 'Fujifilm')}
    assert len(target) == 331
    assets = read(REPORT / 'assets.json')
    by_id = {a['id']:a for a in assets}
    approvals = read(REPORT / 'approved-sources.json')
    approved = {a['id'] for a in approvals}
    assert len(approved) == len(approvals) and approved <= target
    ready_approvals = [a for a in approvals if a['id'] in by_id]
    ready_ids = {a['id'] for a in ready_approvals}
    awaiting_preparation = sorted(approved - ready_ids)
    installed = {a['id'] for a in assets if a.get('status') == 'reviewed-installed'}
    permitted = ready_ids | installed
    for old, new in zip(before['cards'], current['cards']):
        assert {k:v for k,v in old.items() if k != 'color'} == {k:v for k,v in new.items() if k != 'color'}
        if old['id'] not in permitted:
            assert old == new
    for approval in ready_approvals:
        a = by_id[approval['id']]
        assert a['source'] == approval['source']
        assert digest(Path(a['source'])) == approval['sourceSHA256']
        assert digest(Path(a['stagedPath'])) == a['sha256']
        assert a['dimensions'] == [1024, 1024] and a['colorSpace'] == 'sRGB'
    baseline = read(REPORT / 'baseline-hashes.json')
    expected = {'JustShoot/Resources/cards.json'} | {f"JustShoot/Resources/cards/{rows[cid]['image']}" for cid in permitted}
    separate = REPORT / 'concurrent-changes.json'
    independent = read(separate) if separate.exists() else []
    separate_paths = {c['path'] for c in independent}
    assert not expected & separate_paths
    for c in independent:
        assert digest(ROOT / c['path']) == c['observedSHA256']
    changed = {p for p,h in baseline.items() if digest(ROOT / p) != h}
    assert changed <= expected | separate_paths, sorted(changed - expected - separate_paths)
    spec = importlib.util.spec_from_file_location('card_colors', ROOT / 'scripts/compute_card_colors.py')
    colors = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(colors)
    installed_now = []
    for approval in ready_approvals:
        a = by_id[approval['id']]
        destination = ROOT / 'JustShoot/Resources/cards' / rows[a['id']]['image']
        if digest(destination) != a['sha256']:
            shutil.copy2(a['stagedPath'], destination)
            installed_now.append(a['id'])
        color = colors.dominant_color(destination)
        assert color is not None
        rows[a['id']]['color'] = color
        a.update(installedPath=str(destination), color=color, status='reviewed-installed')
    ending = '\n' if CATALOG.read_text().endswith('\n') else ''
    CATALOG.write_text(json.dumps(current, ensure_ascii=False, indent=2) + ending)
    for cid in ready_ids:
        assert digest(Path(by_id[cid]['installedPath'])) == by_id[cid]['sha256']
    changed = {p for p,h in baseline.items() if digest(ROOT / p) != h}
    assert changed <= expected | separate_paths
    write(REPORT / 'assets.json', assets)
    write(REPORT / 'interim-installation.json', {
        'taskComplete':False, 'requested':331, 'generated':len(assets),
        'installed':sum(a.get('status') == 'reviewed-installed' for a in assets),
        'installedNow':installed_now, 'approvedSources':len(approvals),
        'stagedApprovedSources':len(ready_approvals),
        'awaitingPreparation':awaiting_preparation,
        'catalogCount':550, 'scopeAudit':'passed',
        'preserved':'147 Kodak, 72 Fujifilm, nine capture covers and all other app code.',
        'changedAppPaths':sorted(changed - separate_paths),
        'independentChangesPreserved':independent
    })
    print(json.dumps({'installedNow':len(installed_now), 'installedTotal':len(permitted), 'awaitingPreparation':awaiting_preparation, 'taskComplete':False, 'scopeAudit':'passed'}))

if __name__ == '__main__':
    main()
