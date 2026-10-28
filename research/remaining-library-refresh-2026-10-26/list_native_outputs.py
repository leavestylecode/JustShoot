"""Read completed native PNG outputs from built-in image_gen; never generate images."""
from pathlib import Path
import json
import argparse

parser = argparse.ArgumentParser()
parser.add_argument("--after-ns", type=int, default=0)
args = parser.parse_args()

root = Path('/Users/leavestyle/.codex/generated_images/01a16dbb-b5d2-78e1-9195-24f14f709b3c')
files = []
for path in root.glob('exec-*.png'):
    try:
        if args.after_ns and max(path.stat().st_mtime_ns, path.stat().st_ctime_ns) <= args.after_ns:
            continue
        with path.open('rb') as stream:
            assert stream.read(8) == b'\x89PNG\r\n\x1a\n'
            stream.seek(-12, 2)
            assert stream.read(12) == b'\x00\x00\x00\x00IEND\xaeB\x60\x82'
        files.append(path.name)
    except (OSError, AssertionError):
        pass
print(json.dumps(files))
