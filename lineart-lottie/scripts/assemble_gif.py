#!/usr/bin/env python3
"""Slice each motif's frame-grid screenshot into cells and stitch a looping GIF.

Pairs with make_gif_grid.mjs: that emits gifgrid/<name>.html + manifest.json;
you screenshot each grid to gifgrid/<name>.png (natural size); this slices the
PNG back into per-frame cells and writes gifs/<name>.gif.

Usage:
    assemble_gif.py [--grid gifgrid] [--out gifs] [--colors 128]

Deps: Pillow
"""
import argparse
import json
import os

from PIL import Image


def main():
    ap = argparse.ArgumentParser(description="Grid screenshot -> looping GIF")
    ap.add_argument("--grid", default="gifgrid", help="dir with <name>.png + manifest.json")
    ap.add_argument("--out", default="gifs", help="output dir for <name>.gif")
    ap.add_argument("--colors", type=int, default=128, help="adaptive palette size")
    args = ap.parse_args()

    manifest = json.load(open(os.path.join(args.grid, "manifest.json")))
    os.makedirs(args.out, exist_ok=True)

    for name, m in manifest.items():
        png = os.path.join(args.grid, f"{name}.png")
        if not os.path.exists(png):
            print(f"skip {name}: no screenshot at {png}")
            continue
        grid = Image.open(png).convert("RGB")
        cell, cols, n = m["cell"], m["cols"], m["frames"]
        fps = m.get("fps", 30)
        frames = []
        for i in range(n):
            r, c = divmod(i, cols)
            box = (c * cell, r * cell, c * cell + cell, r * cell + cell)
            cellimg = grid.crop(box)
            # adaptive palette keeps the tint clean and the file small
            frames.append(
                cellimg.quantize(colors=args.colors, method=Image.FASTOCTREE, dither=Image.Dither.NONE)
            )
        dur = round(1000 / fps)  # ms per gif frame
        out = os.path.join(args.out, f"{name}.gif")
        frames[0].save(
            out,
            save_all=True,
            append_images=frames[1:],
            duration=dur,
            loop=0,
            disposal=2,
            optimize=True,
        )
        kb = os.path.getsize(out) / 1024
        print(f"{name:12} {n} frames  {cell}x{cell}  {fps:.0f}fps  {kb:6.0f} KB -> {out}")


if __name__ == "__main__":
    main()
