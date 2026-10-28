"""Install fully reviewed remaining-brand covers and audit the resource-only scope."""
from collections import Counter
from io import BytesIO
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import pillow_heif
from PIL import Image, ImageCms

pillow_heif.register_heif_opener()

ROOT = Path(__file__).resolve().parents[2]
REPORT = Path(__file__).resolve().parent
CATALOG = ROOT / 'JustShoot/Resources/cards.json'

def read(path): return json.loads(path.read_text())
def write(path, value): path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')
def digest(path): return hashlib.sha256(path.read_bytes()).hexdigest()

def main():
    before = read(REPORT / 'cards-before.json')
    current = read(CATALOG)
    rows = {c['id']: c for c in current['cards']}
    ids = {c['id'] for c in before['cards'] if c['brand'] not in ('Kodak', 'Fujifilm')}
    assets = read(REPORT / 'assets.json')
    assert len(ids) == len(assets) == 331
    assert {a['id'] for a in assets} == ids
    approvals = read(REPORT / 'approved-sources.json')
    assert len(approvals) == 331
    approved = {a['id']: a for a in approvals}
    assert set(approved) == ids
    selected = {p.stem: read(p) for p in (REPORT / 'generated').glob('*.json')}
    assert set(selected) == ids
    for asset in assets:
        approval = approved[asset['id']]
        assert asset['source'] == approval['source'] == selected[asset['id']]['source']
        assert approval['review'].strip()
        assert digest(Path(asset['source'])) == approval['sourceSHA256']
        staged = Path(asset['stagedPath'])
        assert digest(staged) == asset['sha256']
        with Image.open(staged) as image:
            assert image.size == (1024, 1024)
            assert 'sRGB' in ImageCms.getProfileDescription(ImageCms.ImageCmsProfile(BytesIO(image.info['icc_profile'])))
    review = read(REPORT / 'review-notes.json')
    assert review.get('complete') is True, 'Final visual review is required before installation'
    assert review['finalPagesReviewed'] == list(range(1, 15))
    assert review.get('pendingCorrections') == []
    assert {k:v for k,v in before.items() if k != 'cards'} == {k:v for k,v in current.items() if k != 'cards'}
    assert len(before['cards']) == len(current['cards']) == 550
    for old, new in zip(before['cards'], current['cards']):
        assert {k:v for k,v in old.items() if k != 'color'} == {k:v for k,v in new.items() if k != 'color'}
        if old['id'] not in ids: assert old == new
    baseline = read(REPORT / 'baseline-hashes.json')
    expected = {'JustShoot/Resources/cards.json'} | {f"JustShoot/Resources/cards/{rows[cid]['image']}" for cid in ids}
    separate = REPORT / 'concurrent-changes.json'
    independent = read(separate) if separate.exists() else []
    independent_paths = {c['path'] for c in independent}
    assert not expected & independent_paths
    for c in independent: assert digest(ROOT / c['path']) == c['observedSHA256']
    observed = {p for p,h in baseline.items() if digest(ROOT / p) != h}
    assert observed <= expected | independent_paths, sorted(observed - expected - independent_paths)
    spec = importlib.util.spec_from_file_location('card_colors', ROOT / 'scripts/compute_card_colors.py')
    colors = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(colors)
    old_rows = {c['id']: c for c in before['cards']}
    changes = []
    for a in assets:
        source = Path(a['stagedPath'])
        assert digest(source) == a['sha256']
        destination = ROOT / 'JustShoot/Resources/cards' / rows[a['id']]['image']
        shutil.copy2(source, destination)
        color = colors.dominant_color(destination)
        assert color is not None
        old_color = old_rows[a['id']]['color']
        if old_color != color: changes.append({'id':a['id'], 'before':old_color, 'after':color})
        rows[a['id']]['color'] = color
        a.update(installedPath=str(destination), color=color, status='reviewed-installed')
    ending = '\n' if CATALOG.read_text().endswith('\n') else ''
    CATALOG.write_text(json.dumps(current, ensure_ascii=False, indent=2) + ending)
    changed = {p for p,h in baseline.items() if digest(ROOT / p) != h}
    assert changed - independent_paths == expected
    write(REPORT / 'assets.json', assets)
    write(REPORT / 'asset-validation.json', {
        'covers':331, 'newlyGenerated':331, 'catalogCount':550,
        'format':'HEIC, 1024 x 1024, embedded sRGB ICC',
        'totalBytes':sum(a['bytes'] for a in assets),
        'oldTotalBytes':sum((Path(a['stagedPath']).parent.parent/'before'/(a['id']+'.heic')).stat().st_size for a in assets),
        'colorLabelsChanged':changes,
        'colorDistributionBefore':dict(Counter(c['color'] for c in before['cards'] if c['id'] in ids)),
        'colorDistributionAfter':dict(Counter(rows[cid]['color'] for cid in ids)),
        'changedAppPaths':sorted(expected), 'independentChangesPreserved':independent,
        'catalogAudit':'IDs, order, image bindings and all metadata except target color labels preserved.',
        'scopeAudit':'Only 331 target covers and their color labels changed. Previously approved 147 Kodak, 72 Fujifilm and nine capture covers preserved; other app files match the starting baseline except separately recorded independent changes.'
    })
    print(json.dumps({'installed':len(assets), 'colorLabelsChanged':len(changes), 'scopeAudit':'passed'}))

if __name__ == '__main__': main()
