# Lottie authoring anatomy

What `build_lottie.mjs` emits, and how to tweak it by hand. Lottie/Bodymovin JSON;
frames are integers at `fr` fps. The animation is one shape layer.

## Top level

```jsonc
{
  "v": "5.7.4", "fr": 30, "ip": 0, "op": 210, "w": 240, "h": 240,
  "nm": "lineart leaf", "assets": [], "layers": [ /* one shape layer */ ],
  "markers": [
    { "tm": 0,  "cm": "reveal", "dr": 46 },     // draw-on window
    { "tm": 46, "cm": "idle",   "dr": 164 }      // breath loop window
  ]
}
```

`op` = total frames. Markers let a host loop only the breath: `playSegments([46, 210])`.

## The shape group (draw-on)

Inside the layer, one group `ty:"gr"` holds, in order:

1. **Path shapes** `ty:"sh"` — one per subpath, `ks.k = {c,v[],i[],o[]}` (from
   `svg_to_lottie.parsePath`). `c:false` = open stroke (the usual case for a line).
2. **Stroke** `ty:"st"` — `c.k=[r,g,b,1]` (rgb 0–1, your `--tint`), `w.k` = width,
   `lc:2 lj:2` = round cap/join (smooth pen).
3. **Trim path** `ty:"tm"` — the draw-on. `s` (start) fixed 0; `e` (end) animates
   `0 → 100` from frame 0 to `reveal-end` with a gentle ease-out; `m:1` = trim all
   subpaths together. This is what makes the line *draw itself on*.
4. **Transform** `ty:"tr"` — group transform (identity here).

```jsonc
{ "ty":"tm", "nm":"reveal",
  "s": { "a":0, "k":0 },
  "e": { "a":1, "k":[
    { "t":0,  "s":[0],  "i":{"x":[0.94],"y":[1]}, "o":{"x":[0.25],"y":[0.46]} },
    { "t":46, "s":[100] } ] },
  "o": { "a":0, "k":0 }, "m":1 }
```

## The layer transform (breath)

The seamless breath is a **scale** keyframe on the layer transform — subtle
(100→103→100), symmetric ease-in-out, returning to exactly 100 at `op` so the loop
seam is invisible. Anchor + position are the canvas center so it scales in place.

```jsonc
"s": { "a":1, "k":[
  { "t":46,  "s":[100,100,100], "i":{"x":[0.42],"y":[1]}, "o":{"x":[0.58],"y":[0]} },
  { "t":128, "s":[103,103,100], "i":{"x":[0.42],"y":[1]}, "o":{"x":[0.58],"y":[0]} },
  { "t":210, "s":[100,100,100] } ] }
```

**Seamless-loop rule:** first and last breath values must be identical (both
`[100,100,100]`). If you retime, preserve that or the loop will pop.

## Tweaking

| want | change |
|---|---|
| slower/faster draw | `--reveal-end` (frames to full reveal) |
| longer/slower breath | `--op` (total frames; idle window = op − reveal-end) |
| deeper breath | the middle scale value (103 → e.g. 104) — keep it subtle |
| thicker line | `--stroke` |
| different color | `--tint` |
| different fps | `--fps` (retime reveal-end/op proportionally) |

## Optional flourishes (hand-authored)

The core skill ships stroke + trim + breath. Two extras used in exploration, add by
hand if wanted:

- **Bloom** — a second group with the same path and a radial **gradient fill**
  (`ty:"gf"`, `t:2`) whose opacity fades in once after the reveal (a soft glow
  settling behind the line). Draw the outline group *after* the bloom group so the
  line stays crisp on top.
- **Glitter shimmer** — a **gradient stroke** (`ty:"gs"`) with an animated
  `highlightLength`/offset for a traveling sparkle along the line (used for the
  "butterfly-cat glitter" one-off). Costs more bytes; use sparingly.

Both are legal Bodymovin and render in `lottie-web`; test in `preview.mjs`.
