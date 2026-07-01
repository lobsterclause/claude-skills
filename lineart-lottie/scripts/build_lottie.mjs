#!/usr/bin/env node
// Turn a tracer.py JSON ({viewBox, paths:[d...]}) into a Lottie/Bodymovin JSON:
// a single-line DRAW-ON reveal (trim path) that settles into a SEAMLESS BREATH
// loop, stroked in one colour. Renders in lottie-web (SVG) and lottie-react-native.
//
// Usage:
//   build_lottie.mjs --traced heart-hand.json --out heart-hand.lottie.json \
//     [--tint "#415B4F"] [--name heart-hand] [--reveal-end 46] [--op 210] \
//     [--stroke 3.0] [--fps 30]
//
// Timing (frames @ fps): draw-on 0->reveal-end, breath reveal-end->op (loop seam).
// Defaults give ~1.5s draw + ~5.5s breath at 30fps. Markers: `reveal` and `idle`
// so a host can playSegments([idle, op]) for the seamless loop.
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname } from "node:path";
import { parsePath, roundSub } from "./svg_to_lottie.mjs";

function arg(flag, def) {
  const i = process.argv.indexOf(flag);
  return i >= 0 && i + 1 < process.argv.length ? process.argv[i + 1] : def;
}

const tracedPath = arg("--traced");
if (!tracedPath) {
  console.error("build_lottie: --traced <tracer.json> is required");
  process.exit(2);
}
const traced = JSON.parse(readFileSync(tracedPath, "utf8"));
const VB = traced.viewBox || Number(arg("--viewbox", 240));
const NAME = arg("--name", traced.name || "lineart");
const OUT = arg("--out", `${NAME}.lottie.json`);
const TINT = arg("--tint", "#415B4F");
const FR = Number(arg("--fps", 30));
const REVEAL_END = Number(arg("--reveal-end", 46));
const OP = Number(arg("--op", 210));
const SW = Number(arg("--stroke", 3.0));
const C = VB / 2;

const hexToRgb01 = (h) => {
  const n = parseInt(h.replace("#", ""), 16);
  return [((n >> 16) & 255) / 255, ((n >> 8) & 255) / 255, (n & 255) / 255];
};
const [r, g, b] = hexToRgb01(TINT);

// easing: gentle ease-out for the draw-on, symmetric ease-in-out for the breath
const eOG = { i: { x: [0.94], y: [1] }, o: { x: [0.25], y: [0.46] } };
const eIO = { i: { x: [0.42], y: [1] }, o: { x: [0.58], y: [0] } };

const shapes = traced.paths.map((d, i) => ({
  ty: "sh",
  nm: "p" + i,
  ks: { a: 0, k: roundSub(parsePath(d)[0]) },
}));

const group = {
  ty: "gr",
  nm: "line",
  it: [
    ...shapes,
    {
      ty: "st",
      nm: "stroke",
      c: { a: 0, k: [r, g, b, 1] },
      o: { a: 0, k: 100 },
      w: { a: 0, k: SW },
      lc: 2,
      lj: 2,
      ml: 4,
      bm: 0,
    },
    {
      ty: "tm",
      nm: "reveal",
      s: { a: 0, k: 0 },
      e: { a: 1, k: [{ t: 0, s: [0], ...eOG }, { t: REVEAL_END, s: [100] }] },
      o: { a: 0, k: 0 },
      m: 1,
    },
    {
      ty: "tr",
      p: { a: 0, k: [0, 0] },
      a: { a: 0, k: [0, 0] },
      s: { a: 0, k: [100, 100] },
      r: { a: 0, k: 0 },
      o: { a: 0, k: 100 },
    },
  ],
};

const layer = {
  ddd: 0,
  ind: 1,
  ty: 4,
  nm: NAME,
  sr: 1,
  ks: {
    o: { a: 0, k: 100 },
    r: { a: 0, k: 0 },
    p: { a: 0, k: [C, C] },
    a: { a: 0, k: [C, C] },
    // breath: 100 -> 103 -> 100 across the idle window (seamless at op)
    s: {
      a: 1,
      k: [
        { t: REVEAL_END, s: [100, 100, 100], ...eIO },
        { t: REVEAL_END + Math.round((OP - REVEAL_END) / 2), s: [103, 103, 100], ...eIO },
        { t: OP, s: [100, 100, 100] },
      ],
    },
  },
  ao: 0,
  shapes: [group],
  ip: 0,
  op: OP,
  st: 0,
  bm: 0,
};

const lottie = {
  v: "5.7.4",
  fr: FR,
  ip: 0,
  op: OP,
  w: VB,
  h: VB,
  nm: `lineart ${NAME}`,
  ddd: 0,
  assets: [],
  layers: [layer],
  markers: [
    { tm: 0, cm: "reveal", dr: REVEAL_END },
    { tm: REVEAL_END, cm: "idle", dr: OP - REVEAL_END },
  ],
};

mkdirSync(dirname(OUT) || ".", { recursive: true });
const json = JSON.stringify(lottie);
writeFileSync(OUT, json);
console.log(
  `wrote ${OUT}  ${(json.length / 1024).toFixed(1)}KB  ${traced.paths.length} strokes  tint ${TINT}  op ${OP} reveal ${REVEAL_END}`,
);
