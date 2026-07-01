#!/usr/bin/env node
// Emit a frame-grid HTML per Lottie: one frozen lottie instance per frame
// (goToAndStop), laid out in exact CELL-px cells with no gaps, so ONE screenshot
// of the page can be sliced back into GIF frames by assemble_gif.py.
//
// Usage:
//   make_gif_grid.mjs --outdir gifgrid --cols 12 --cell 240 motif.lottie.json ...
//
// Then screenshot each gifgrid/<name>.html at its natural size (the page sets
// document.title = "READY" once every cell has painted), e.g.:
//   chromium --headless=new --hide-scrollbars --window-size=<cols*cell>,<rows*cell> \
//            --screenshot=gifgrid/<name>.png "file://$PWD/gifgrid/<name>.html"
// then: python assemble_gif.py --grid gifgrid --out gifs
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { basename } from "node:path";

const LOTTIE_CDN =
  process.env.LOTTIE_CDN ||
  "https://cdnjs.cloudflare.com/ajax/libs/bodymovin/5.12.2/lottie.min.js";

function arg(flag, def) {
  const i = process.argv.indexOf(flag);
  return i >= 0 && i + 1 < process.argv.length ? process.argv[i + 1] : def;
}
const outdir = arg("--outdir", "gifgrid");
const COLS = Number(arg("--cols", 12));
const CELL = Number(arg("--cell", 240));
const STEP = Number(arg("--step", 1)); // source frames per gif frame (1 = full fps)
const files = process.argv
  .slice(2)
  .filter((a) => a.endsWith(".json") && !a.startsWith("--"));
if (!files.length) {
  console.error("make_gif_grid: pass one or more *.json Lottie files");
  process.exit(2);
}
mkdirSync(outdir, { recursive: true });

const manifest = {};
for (const f of files) {
  const name = basename(f).replace(/\.(lottie\.)?json$/, "");
  const data = JSON.parse(readFileSync(f, "utf8"));
  const OP = data.op;
  const frames = [];
  for (let fr = 0; fr < OP; fr += STEP) frames.push(fr);
  const rows = Math.ceil(frames.length / COLS);
  manifest[name] = { frames: frames.length, cols: COLS, rows, cell: CELL, fps: data.fr / STEP };
  const cells = frames
    .map((fr) => `<div class="c"><div class="a" data-f="${fr}"></div></div>`)
    .join("");
  const html = `<!doctype html><meta charset=utf-8><style>
*{margin:0;padding:0;box-sizing:border-box}html,body{background:#fff}
.grid{display:grid;grid-template-columns:repeat(${COLS},${CELL}px);width:${COLS * CELL}px}
.c{width:${CELL}px;height:${CELL}px;display:flex;align-items:center;justify-content:center;background:#fff}
.a{width:${Math.round(CELL * 0.8)}px;height:${Math.round(CELL * 0.8)}px}
</style><div class="grid">${cells}</div>
<script src="${LOTTIE_CDN}"></script><script>window.HD=${JSON.stringify(data)};</script>
<script>let p=0;document.querySelectorAll(".a").forEach(el=>{p++;const a=lottie.loadAnimation({container:el,renderer:"svg",loop:false,autoplay:false,animationData:JSON.parse(JSON.stringify(window.HD))});a.addEventListener("DOMLoaded",()=>{a.goToAndStop(+el.dataset.f,true);if(--p===0)document.title="READY";});});</script>`;
  writeFileSync(`${outdir}/${name}.html`, html);
}
writeFileSync(`${outdir}/manifest.json`, JSON.stringify(manifest, null, 2));
console.log(`wrote ${Object.keys(manifest).length} grids to ${outdir}/ (cols ${COLS}, cell ${CELL}, step ${STEP})`);
for (const [n, m] of Object.entries(manifest))
  console.log(`  ${n.padEnd(12)} ${m.frames} frames ${m.cols}x${m.rows} @ ${m.fps}fps`);
