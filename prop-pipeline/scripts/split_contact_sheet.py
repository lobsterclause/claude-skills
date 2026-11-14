#!/usr/bin/env python3
"""Split a 2x2 contact sheet into canonical front/left/back/right panels.

Layout assumed (matches the contact-sheet prompt in SKILL.md):
  top-left = front, top-right = left, bottom-left = back, bottom-right = right.

Usage:
  python split_contact_sheet.py <sheet.png> <out_dir>
Writes <out_dir>/{front,left,back,right}.png and prints the paths.

Needs Pillow; run under uv if it isn't installed:
  uv run --with pillow python split_contact_sheet.py <sheet.png> <out_dir>
"""
import sys
from pathlib import Path

from PIL import Image

if len(sys.argv) != 3:
    print(__doc__)
    sys.exit(1)

sheet = Path(sys.argv[1]).expanduser()
out_dir = Path(sys.argv[2]).expanduser()
out_dir.mkdir(parents=True, exist_ok=True)

im = Image.open(sheet)
w, h = im.size
hw, hh = w // 2, h // 2
slots = {
    "front": (0, 0, hw, hh),
    "left": (hw, 0, w, hh),
    "back": (0, hh, hw, h),
    "right": (hw, hh, w, h),
}
for name, box in slots.items():
    out = out_dir / f"{name}.png"
    im.crop(box).save(out)
    print(out)
