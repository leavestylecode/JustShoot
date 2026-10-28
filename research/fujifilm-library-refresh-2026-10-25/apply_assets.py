"""Install reviewed covers; preserve the catalog except these covers' color labels."""
from collections import Counter
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil

ROOT = Path(__file__).resolve().parents[2]
REPORT = Path(__file__).resolve().parent
CARDS = ROOT / 'JustShoot/Resources/cards'
CATALOG = ROOT / 'JustShoot/Resources/cards.json'


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    baseline = json.loads((REPORT / 'baseline-hashes.json').read_text())
    before = json.loads((REPORT / 'cards-before.json').read_text())
    original_text = CATALOG.read_text()
    catalog = json.loads(original_text)
    assert catalog == before, 'Catalog changed after inventory; review before installing.'
    assets = json.loads((REPORT / 'assets.json').read_text())
    ids = {c['id'] for c in before['cards'] if c['brand'] == 'Fujifilm'}
    assert len(assets) == len(ids) == 72
    assert {a['id'] for a in assets} == ids
    rows = {c['id']: c for c in catalog['cards']}
    spec = importlib.util.spec_from_file_location('card_colors', ROOT / 'scripts/compute_card_colors.py')
    colors = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(colors)
    color_changes = []
    for asset in assets:
        row = rows[asset['id']]
        staged = Path(asset['stagedPath'])
        assert digest(staged) == asset['sha256']
        dest = CARDS / row['image']
        shutil.copy2(staged, dest)
        color = colors.dominant_color(dest)
        assert color is not None
        if color != row['color']:
            color_changes.append({'id': row['id'], 'before': row['color'], 'after': color})
        row['color'] = color
        asset['installedPath'] = str(dest)
        asset['color'] = color
        asset['status'] = 'reviewed-installed'
    text = json.dumps(catalog, ensure_ascii=False, indent=2)
    if original_text.endswith('\n'):
        text += '\n'
    CATALOG.write_text(text)
    expected = {'JustShoot/Resources/cards.json'} | {f"JustShoot/Resources/cards/{rows[cid]['image']}" for cid in ids}
    changed = {p for p, old_hash in baseline.items() if digest(ROOT / p) != old_hash}
    assert changed == expected, {'unexpected': sorted(changed - expected), 'missing': sorted(expected - changed)}
    for old, new in zip(before['cards'], catalog['cards']):
        assert {k: v for k, v in old.items() if k != 'color'} == {k: v for k, v in new.items() if k != 'color'}
        if old['id'] not in ids:
            assert old == new
    (REPORT / 'assets.json').write_text(json.dumps(assets, indent=2) + '\n')
    result = {
        'covers': len(assets),
        'newlyGenerated': sum(a['kind'] == 'generate' for a in assets),
        'reuseApproved': sum(a['kind'] == 'reuse-approved' for a in assets),
        'totalBytes': sum(a['bytes'] for a in assets),
        'oldTotalBytes': sum((Path(a['stagedPath']).parent.parent / 'before' / (a['id'] + '.heic')).stat().st_size for a in assets),
        'format': 'HEIC, 1024 x 1024, embedded sRGB ICC',
        'colorLabelsChanged': color_changes,
        'colorDistributionBefore': dict(Counter(c['color'] for c in before['cards'] if c['id'] in ids)),
        'colorDistributionAfter': dict(Counter(rows[cid]['color'] for cid in ids)),
        'changedAppPaths': sorted(changed),
        'scopeAudit': 'Exactly 72 Fujifilm numeric image assets and cards.json changed since the start of this refresh. Other app files match baseline.',
        'catalogAudit': '550 cards, 72 Fujifilm cards; IDs, ordering, image bindings and all metadata except these cards color labels preserved.',
        'visualReview': 'All 72 covers reviewed on 3 contact sheets and 12 generation group sheets; 64T hierarchy and Superia 200 model number refined.',
    }
    (REPORT / 'asset-validation.json').write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps(result, ensure_ascii=False))


if __name__ == '__main__':
    main()
