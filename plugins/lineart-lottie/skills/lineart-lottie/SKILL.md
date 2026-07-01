---
name: lineart-lottie
description: Generate on-brand single-line "line-art" Lottie animations end-to-end — image-gen a line-art raster, centerline-vectorize it into one continuous stroke, author a Lottie that draws itself on then settles into a seamless breathing loop, preview it, and optionally export a looping GIF. Use this skill whenever the user wants a hand-drawn / line-art / single-line motion mark, an animated icon or empty-state illustration, a Lottie/Bodymovin animation from an image or a described motif, a draw-on "self-drawing" SVG animation, or a set of matching animated motifs in a house style — even if they don't say "Lottie" (phrases like "animate this line drawing", "make a self-drawing heart", "turn this sketch into an animation", "an animated empty-state illustration", "matching animated icons in our style", "vectorize this and animate it drawing on", "export it as a looping gif" all trigger it). The skill covers the whole pipeline: generate → centerline-trace (skeletonize + single-line route-ordering) → Lottie authoring (trim-path draw-on + breath loop + markers, solid or per-persona tint) → HTML preview → GIF. Do NOT trigger for generic video editing, 3D/model generation, or when the user already has a finished Lottie and only wants it embedded.
---

# lineart-lottie

Turn a described motif (or an existing image/sketch) into a polished **single-line-art Lottie**: one continuous stroke that draws itself on, then settles into a gentle seamless breath loop. Renders in `lottie-web` (web) and `lottie-react-native` (mobile). Optional looping-GIF export for sharing.

The pipeline was built and proven on the Kindred Mama / NEM design system (a hand-cradling-a-heart empty state + a 10-motif nature set), but nothing here is app-specific — point it at any style.

## The pipeline (5 stages)

```
 generate            vectorize                author                 preview        export (optional)
 ─────────           ──────────               ──────                 ───────        ────────
 line-art raster  →  tracer.py (centerline)  →  build_lottie.mjs   →  preview.mjs → make_gif_grid.mjs
 (image-gen)         skeleton → single-line     draw-on trim reveal    lottie-web    + screenshot
                     route order → beziers      + breath loop +        seamless      + assemble_gif.py
                     → {viewBox, paths}         markers + tint         loop
```

Each stage is one script; you can start at stage 2 if you already have a raster, or stage 3 if you already have traced paths.

## Setup (once)

```bash
bash scripts/setup.sh            # creates ./.venv with numpy/Pillow/scikit-image/scipy
```

Node scripts use only built-ins (v18+). `preview.mjs` / `make_gif_grid.mjs` load `lottie-web` from a CDN (override with `LOTTIE_CDN=…`).

## Stage 1 — generate a line-art raster

You need a **clean, single-weight black line drawing on white** (no fills, no shading — the tracer follows ink centerlines). Generate one with an image model. The proven route is the **codex CLI** image tool (GPT Image, uses the ChatGPT subscription — no `OPENAI_API_KEY` needed):

```bash
printf '%s' "PROMPT_HERE" | codex exec --skip-git-repo-check --sandbox workspace-write -C /tmp
```

Alternatively use any image MCP tool available in-session (e.g. an `openai_generate_image` tool). See [`references/style-prompts.md`](references/style-prompts.md) for the NEM house-style prompt template and the exact motif prompts — the key phrases are *"single continuous line, one weight, black on white, no shading, no fill, centered, generous margin."*

Save the raster (PNG) somewhere, e.g. `work/leaf.png`.

## Stage 2 — vectorize (centerline trace)

```bash
.venv/bin/python scripts/tracer.py work/leaf.png leaf --viewbox 240 --svg-out work/svg > work/traced/leaf.json
```

- Composites on white → ink mask → **skeletonize** → walks the skeleton into branches → **`order_strokes`** chains them into a continuous single-line draw path (straight-through at junctions, nearest-neighbour pen-lifts) → RDP simplify → Catmull-Rom cubic beziers → fits to a square viewBox.
- Emits `{name, viewBox, rawBranches, kept, paths:[d…]}` on **stdout** (redirect to a file). `--svg-out DIR` also writes `leaf.svg` so you can eyeball the trace.
- Tuning: `--rdp` (higher = simpler/smoother, fewer points), `--min-len` (drop tiny strokes), `--pad`. If the draw-on later looks jumpy, the trace has too many disjoint subpaths — raise `--rdp` or clean the source raster (the single biggest quality lever is a clean, truly single-line input).

## Stage 3 — author the Lottie

```bash
node scripts/build_lottie.mjs --traced work/traced/leaf.json --out work/lottie/leaf.json \
  --tint "#3D8A6B" --reveal-end 46 --op 210 --stroke 3.0
```

Produces a Lottie whose stroke **draws on** (trim path `ty:"tm"`, 0→100% over `reveal-end` frames) then **breathes** (layer scale 100→103→100 across `reveal-end`→`op`, easing to a seamless loop at `op`). Adds `reveal` and `idle` markers so a host can loop just the breath: `playSegments([idle, op])`.

- `--tint` hex (baked into the stroke). `--reveal-end`/`--op` are frames at `--fps` (default 30): defaults ≈ 1.5 s draw + 5.5 s breath. `--stroke` width in viewBox units.
- Output is compact JSON (typically 4–40 KB). See [`references/lottie-authoring.md`](references/lottie-authoring.md) for the trim-path / breath / marker anatomy and how to tweak timing.

## Stage 4 — preview

```bash
node scripts/preview.mjs --out work/preview.html work/lottie/*.json
open work/preview.html          # or screenshot it to review
```

A self-contained page: each motif draws on once (staggered), then loops the idle segment **seamlessly** — the exact pattern a real host uses. Review timing, tint legibility, and loop-seam smoothness here before shipping.

## Stage 5 — export a looping GIF (optional, for sharing)

Lottie is the shippable artifact; GIFs are just for showing people who can't render Lottie.

```bash
node scripts/make_gif_grid.mjs --outdir work/gifgrid --cols 12 --cell 240 work/lottie/leaf.json
# screenshot each grid at natural size (title flips to "READY" when painted):
chromium --headless=new --hide-scrollbars --window-size=2880,1000 \
  --screenshot=work/gifgrid/leaf.png "file://$PWD/work/gifgrid/leaf.html"
.venv/bin/python scripts/assemble_gif.py --grid work/gifgrid --out work/gifs
```

`make_gif_grid.mjs` lays every frame out as frozen `goToAndStop` cells in an exact grid; you screenshot the page (headless Chrome/Chromium, or any full-page screenshot tool); `assemble_gif.py` slices the cells back into a looping GIF at the source fps. Keep `--cell`/`--cols` in sync between the two (the manifest carries them). For crisp GIFs use full fps (`--step 1`) and a modest adaptive palette (`--colors 128`).

## Consuming the Lottie in an app

For a React host that plays draw-on → seamless breath **and honors `prefers-reduced-motion`** (a CSS reduced-motion kill-switch does NOT stop a JS/SVG Lottie — the host must), see [`references/host-integration.md`](references/host-integration.md). It has a drop-in `lottie-react` component and the pure `plan(data)` helper that derives the poster frame + idle segment from the markers.

## Quality bar / gotchas

- **Clean single-line input is 80% of quality.** Fills, double strokes, and shading make the skeleton fork; the draw-on then jumps between disjoint pieces. Prompt hard for one continuous line; re-generate rather than fighting a messy raster.
- **numpy 2.x** removed the scalar `np.cross` — `tracer.py` uses a manual 2D cross; don't "fix" it back.
- **Seamless loop** requires the breath keyframes to return exactly to the start value at `op` (they do). If you retime, keep the first and last breath values identical.
- **Reduced motion**: always ship the host reduced-motion poster (see host-integration) — the animation is decorative and must be stoppable.
- See [`references/pipeline.md`](references/pipeline.md) for the full design rationale and stage-by-stage internals.

## References

- [`references/pipeline.md`](references/pipeline.md) — end-to-end design, each stage's internals, tuning.
- [`references/style-prompts.md`](references/style-prompts.md) — house-style image-gen prompt template + the exact motif prompts.
- [`references/lottie-authoring.md`](references/lottie-authoring.md) — Lottie anatomy (trim path, breath, markers, tint, gradient shimmer).
- [`references/host-integration.md`](references/host-integration.md) — React/`lottie-react` host with reduced-motion + seamless loop.
