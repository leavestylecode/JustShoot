"""Create a small display copy, preserving the generated cover content."""
from pathlib import Path
import sys
from PIL import Image

source, target = map(Path, sys.argv[1:3])
target.parent.mkdir(parents=True, exist_ok=True)
image = Image.open(source).convert('RGB')
image.thumbnail((384, 384), Image.Resampling.LANCZOS)
image.save(target, quality=84)
