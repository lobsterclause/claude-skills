#!/usr/bin/env python3
"""Centerline raster -> SVG/JSON tracer for single-line line-art.

Pipeline: composite-on-white -> ink mask (distance from white) -> skeletonize
-> walk skeleton graph into branches -> route-order into continuous single-line
strokes (straight-through at junctions, nearest-neighbour pen-lifts) -> RDP
simplify -> Catmull-Rom cubic beziers -> fit to a square viewBox.

Emits JSON {name, viewBox, rawBranches, kept, paths:[d...]} on stdout, and
(optionally) an SVG for eyeballing.

Usage:
    tracer.py INPUT.png NAME [--viewbox 240] [--pad 18] [--rdp 1.4]
                             [--min-len 10] [--svg-out DIR]

Deps: numpy, Pillow, scikit-image, scipy  (see scripts/setup.sh)
"""
import argparse
import json
import os
import sys

import numpy as np
from PIL import Image
from skimage.morphology import (
    skeletonize,
    remove_small_objects,
    closing,
    disk,
)


def load_ink(path):
    im = Image.open(path).convert("RGBA")
    arr = np.asarray(im).astype(np.float32)
    rgb, a = arr[..., :3], arr[..., 3:4] / 255.0
    rgb = rgb * a + 255.0 * (1 - a)          # composite on white
    ink = 255.0 - rgb.min(axis=2)            # distance-from-white per pixel
    return ink


def ink_mask(ink, thresh=55, min_size=40):
    m = ink > thresh
    m = closing(m, disk(1))                      # binary closing (bridges 1px gaps)
    try:                                          # skimage >=0.26 renamed the arg
        m = remove_small_objects(m, max_size=min_size - 1)
    except TypeError:
        m = remove_small_objects(m, min_size=min_size)
    return m


NEIGH = [(-1, -1), (-1, 0), (-1, 1), (0, -1), (0, 1), (1, -1), (1, 0), (1, 1)]


def walk_skeleton(skel):
    S = set(map(tuple, np.argwhere(skel)))

    def nb(p):
        return [(p[0] + dr, p[1] + dc) for dr, dc in NEIGH if (p[0] + dr, p[1] + dc) in S]

    deg = {p: len(nb(p)) for p in S}
    used = set()

    def edge(a, b):
        return (a, b) if a <= b else (b, a)

    def walk(start, second):
        path = [start, second]
        used.add(edge(start, second))
        prev, cur = start, second
        while deg[cur] == 2:
            nxts = [q for q in nb(cur) if q != prev and edge(cur, q) not in used]
            if not nxts:
                break
            nxt = nxts[0]
            used.add(edge(cur, nxt))
            path.append(nxt)
            prev, cur = cur, nxt
        return path

    paths = []
    for n in [p for p in S if deg[p] != 2]:          # start from endpoints/junctions
        for q in nb(n):
            if edge(n, q) not in used:
                paths.append(walk(n, q))
    for p in S:                                       # remaining pure loops
        for q in nb(p):
            if edge(p, q) not in used:
                paths.append(walk(p, q))
    return paths


def rdp(pts, eps):
    if len(pts) < 3:
        return pts
    a, b = np.array(pts[0], float), np.array(pts[-1], float)
    ab = b - a
    L = np.hypot(*ab) or 1.0
    dmax, idx = 0.0, 0
    for i in range(1, len(pts) - 1):
        p = np.array(pts[i], float)
        pa = p - a
        d = abs(ab[0] * pa[1] - ab[1] * pa[0]) / L   # 2D cross (numpy 2.x dropped np.cross scalar)
        if d > dmax:
            dmax, idx = d, i
    if dmax > eps:
        return rdp(pts[: idx + 1], eps)[:-1] + rdp(pts[idx:], eps)
    return [pts[0], pts[-1]]


def catmull_to_bezier(pts):
    """pts: list of (x,y). Returns an SVG path `d` with cubic beziers through them."""
    if len(pts) < 2:
        return ""
    P = [np.array(p, float) for p in pts]
    d = f"M{P[0][0]:.2f} {P[0][1]:.2f}"
    n = len(P)
    for i in range(n - 1):
        p0 = P[i - 1] if i > 0 else P[i]
        p1, p2 = P[i], P[i + 1]
        p3 = P[i + 2] if i + 2 < n else P[i + 1]
        c1 = p1 + (p2 - p0) / 6.0
        c2 = p2 - (p3 - p1) / 6.0
        d += f" C{c1[0]:.2f} {c1[1]:.2f} {c2[0]:.2f} {c2[1]:.2f} {p2[0]:.2f} {p2[1]:.2f}"
    return d


def _dir(a, b):
    v = (b[0] - a[0], b[1] - a[1])
    n = (v[0] ** 2 + v[1] ** 2) ** 0.5 or 1.0
    return (v[0] / n, v[1] / n)


def order_strokes(branches, snap=3.0, bridge=6.0):
    """Chain skeleton branches into continuous ordered strokes that follow the
    drawing path: go straight-through at junctions, nearest-neighbour pen-lifts
    only when a stroke dead-ends. Yields the single-line reveal order."""
    from collections import defaultdict

    reps = []

    def rep(p):
        for q in reps:
            if abs(p[0] - q[0]) <= snap and abs(p[1] - q[1]) <= snap:
                return q
        reps.append(p)
        return p

    B = []
    for pth in branches:
        if len(pth) >= 2:
            B.append({"pts": pth, "a": rep(pth[0]), "b": rep(pth[-1])})
    if not B:
        return []

    inc = defaultdict(list)
    for i, br in enumerate(B):
        inc[br["a"]].append(i)
        if br["b"] != br["a"]:
            inc[br["b"]].append(i)

    visited = set()

    def take(bi, node):
        br = B[bi]
        return (br["pts"], br["b"]) if br["a"] == node else (br["pts"][::-1], br["a"])

    strokes, cur_stroke = [], []
    nodes = list(inc.keys())
    odd = [n for n in nodes if len(inc[n]) % 2 == 1]
    cur, incoming = (odd or nodes)[0], None

    while len(visited) < len(B):
        cand = [bi for bi in inc[cur] if bi not in visited]
        if cand:
            if incoming is None:
                bi = cand[0]
            else:                                   # continue straightest through the junction
                bi, bestdot = cand[0], -2.0
                for c in cand:
                    pts, _ = take(c, cur)
                    d = _dir(pts[0], pts[min(3, len(pts) - 1)])
                    dot = incoming[0] * d[0] + incoming[1] * d[1]
                    if dot > bestdot:
                        bestdot, bi = dot, c
            visited.add(bi)
            pts, far = take(bi, cur)
            if cur_stroke and abs(cur_stroke[-1][0] - pts[0][0]) + abs(cur_stroke[-1][1] - pts[0][1]) <= bridge:
                cur_stroke.extend(pts[1:] if cur_stroke[-1] == pts[0] else pts)
            else:
                if cur_stroke:
                    strokes.append(cur_stroke)
                cur_stroke = list(pts)
            incoming = _dir(pts[max(0, len(pts) - 4)], pts[-1])
            cur = far
        else:                                        # dead end -> pen lift to nearest unvisited
            if cur_stroke:
                strokes.append(cur_stroke)
                cur_stroke = []
            remaining = [bi for bi in range(len(B)) if bi not in visited]
            if not remaining:
                break
            bi, bestd, node = remaining[0], 1e18, B[remaining[0]]["a"]
            for r in remaining:
                for nd in (B[r]["a"], B[r]["b"]):
                    d = (nd[0] - cur[0]) ** 2 + (nd[1] - cur[1]) ** 2
                    if d < bestd:
                        bestd, node = d, nd
            cur, incoming = node, None
    if cur_stroke:
        strokes.append(cur_stroke)
    return strokes


def trace(path, viewbox=240, pad=18, rdp_eps=1.4, min_len=10):
    ink = load_ink(path)
    m = ink_mask(ink)
    skel = skeletonize(m)
    raw = walk_skeleton(skel)
    strokes = order_strokes(raw)

    polys = []
    for p in strokes:
        if len(p) < 3:
            continue
        xy = [(c, r) for (r, c) in p]              # (row,col)->(x,y)
        simp = rdp(xy, rdp_eps)
        length = sum(
            np.hypot(simp[i + 1][0] - simp[i][0], simp[i + 1][1] - simp[i][1])
            for i in range(len(simp) - 1)
        )
        if length >= min_len:
            polys.append(simp)

    if not polys:
        raise SystemExit(f"tracer: no strokes survived for {path} (raw branches={len(raw)})")

    # fit to viewBox
    allpts = np.array([pt for poly in polys for pt in poly], float)
    mn, mx = allpts.min(0), allpts.max(0)
    span = (mx - mn).max() or 1.0
    scale = (viewbox - 2 * pad) / span
    off = (mn + mx) / 2.0
    ctr = viewbox / 2.0

    def T(pt):
        return ((pt[0] - off[0]) * scale + ctr, (pt[1] - off[1]) * scale + ctr)

    ds = [catmull_to_bezier([T(pt) for pt in poly]) for poly in polys]
    return ds, viewbox, len(raw), len(polys)


def main():
    ap = argparse.ArgumentParser(description="Centerline raster -> single-line SVG/JSON tracer")
    ap.add_argument("input", help="input raster (png/jpg)")
    ap.add_argument("name", help="motif name (used for the SVG filename)")
    ap.add_argument("--viewbox", type=int, default=240)
    ap.add_argument("--pad", type=int, default=18)
    ap.add_argument("--rdp", type=float, default=1.4, help="RDP epsilon (higher = simpler)")
    ap.add_argument("--min-len", type=float, default=10.0)
    ap.add_argument("--svg-out", default=None, help="dir to also write NAME.svg for preview")
    args = ap.parse_args()

    ds, vb, nraw, nkept = trace(
        args.input, args.viewbox, args.pad, args.rdp, args.min_len
    )

    if args.svg_out:
        os.makedirs(args.svg_out, exist_ok=True)
        svg = (
            f'<svg xmlns="http://www.w3.org/2000/svg" width="{vb}" height="{vb}" viewBox="0 0 {vb} {vb}">'
            + "".join(
                f'<path d="{d}" fill="none" stroke="#333" stroke-width="2.2" '
                'stroke-linecap="round" stroke-linejoin="round"/>'
                for d in ds
            )
            + "</svg>"
        )
        with open(os.path.join(args.svg_out, f"{args.name}.svg"), "w") as f:
            f.write(svg)
        print(f"wrote {args.svg_out}/{args.name}.svg", file=sys.stderr)

    print(json.dumps({"name": args.name, "viewBox": vb, "rawBranches": nraw, "kept": nkept, "paths": ds}))


if __name__ == "__main__":
    main()
