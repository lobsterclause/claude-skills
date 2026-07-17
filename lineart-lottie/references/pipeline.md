# Pipeline internals & design rationale

The goal: from a *described* motif to a shippable **single-line-art Lottie** that
feels hand-drawn — it draws itself on, then breathes. Five stages, each a script.

## Why centerline vectorization (not a normal tracer)

Off-the-shelf raster tracers (potrace, ImageTrace) trace the **outline** of ink —
so a drawn line becomes a thin closed loop (two edges + two caps). That animates
as a filling ribbon, not a drawing pen. We want the **centerline**: the 1-px
medial skeleton of the ink, walked as an open polyline, so a trim-path reveal
looks like a single pen drawing the shape. That's what `tracer.py` does.

## Stage 2 internals (`tracer.py`)

1. **Ink field** — composite RGBA on white, take `255 - min(r,g,b)` per pixel → a
   "distance from white" field robust to anti-aliasing and colored line-art.
2. **Mask** — threshold, `binary_closing(disk 1)` to bridge 1-px gaps,
   `remove_small_objects` to drop speckle.
3. **Skeletonize** (`skimage.morphology.skeletonize`) → 1-px medial skeleton.
4. **Walk** (`walk_skeleton`) — 8-connectivity graph; start at endpoints/junctions
   (degree ≠ 2), walk degree-2 chains into branches; mop up pure loops.
5. **Route-order** (`order_strokes`) — the quality step. Skeleton branches come out
   in arbitrary order; drawn naively the reveal teleports around. This chains
   branches into continuous strokes: at a junction it continues **straightest**
   (max dot-product of incoming vs candidate direction), and only lifts the pen
   (nearest-neighbour jump) when a stroke genuinely dead-ends. Node clustering
   (`snap`) merges near-coincident junction points; `bridge` stitches strokes
   whose ends nearly touch. This roughly halves the subpath count and makes the
   draw-on read as one hand.
6. **Simplify** — Ramer–Douglas–Peucker (`--rdp`, default 1.4) thins dense skeleton
   points. Uses a manual 2-D cross product (numpy 2.x dropped the scalar
   `np.cross`).
7. **Smooth** — Catmull-Rom → cubic bezier (`catmull_to_bezier`) for organic curves
   through the simplified points.
8. **Fit** — scale/center all strokes into a square `--viewbox` with `--pad`.

Output: `{name, viewBox, rawBranches, kept, paths:[SVG "d"…]}` on stdout.
`rawBranches` vs `kept` tells you how much the ordering/pruning collapsed.

**Tuning:** clean input first (see below), then `--rdp` up for smoother/simpler,
`--min-len` up to drop stray ticks, `--pad` for breathing room. If subpaths stay
high (say >20 for a simple motif) the raster isn't truly single-line — fix the
source, don't crank RDP.

## Stage 3 internals (`build_lottie.mjs` + `svg_to_lottie.mjs`)

- `svg_to_lottie.mjs` (`parsePath`) converts each SVG `d` into a Lottie shape path
  `{c, v[], i[], o[]}` — Lottie stores bezier tangents **vertex-relative** (in/out
  handles as deltas), so cubic control points are converted to `o[prev]` and
  `i[cur]` deltas. Handles M/L/H/V/C/S/Q/T/Z, absolute & relative, implicit repeats.
- `build_lottie.mjs` assembles one shape layer:
  - group = all path shapes + one **stroke** (`ty:"st"`, your tint) + a **trim
    path** (`ty:"tm"`, `e` 0→100 over `reveal-end`, gentle ease-out) = the draw-on.
  - layer transform **scale** keyframes 100→103→100 across `reveal-end`→`op` = the
    breath, returning exactly to start for a seamless loop.
  - `markers`: `reveal` (0..reveal-end) and `idle` (reveal-end..op) so a host loops
    only the breath.

See `lottie-authoring.md` for the exact JSON shapes.

## Stage 4 (`preview.mjs`) & Stage 5 (`make_gif_grid.mjs` + `assemble_gif.py`)

- Preview mounts each Lottie with `lottie-web`, plays `[0, op]` once, then on
  `complete` flips `loop=true` and `playSegments([idle, op])` — the seamless breath.
- GIF path renders every frame as a frozen `goToAndStop` cell in an exact pixel
  grid (one screenshot = all frames), then slices + stitches with Pillow. Full fps
  (`--step 1`) and adaptive palette keep it crisp and small.

## The single biggest quality lever

**A clean, truly single-weight line drawing on white.** Everything downstream is
deterministic; the only real variable is the raster. Prompt for *one continuous
line, one weight, black on white, no fill, no shading, centered, generous margin*
and re-generate until you get it. A messy raster (fills, doubled strokes, cross-
hatching) forks the skeleton and no amount of RDP hides the resulting pen-jumps.
