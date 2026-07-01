#!/usr/bin/env node
// Write a self-contained HTML player for one or more Lottie JSONs. Each animation
// draws itself on once, then loops the `idle` marker segment SEAMLESSLY (the same
// playSegments([idle, op]) pattern a real host uses). Loads lottie-web from a CDN.
//
// Usage:
//   preview.mjs --out preview.html motif1.lottie.json [motif2.lottie.json ...]
//   preview.mjs --out preview.html --stagger 90 --bg "#faf7f4" *.lottie.json
//
// Open the file in a browser (or screenshot it) to review timing/tint/legibility.
import { readFileSync, writeFileSync } from "node:fs";
import { basename } from "node:path";

const LOTTIE_CDN =
  process.env.LOTTIE_CDN ||
  "https://cdnjs.cloudflare.com/ajax/libs/bodymovin/5.12.2/lottie.min.js";

function arg(flag, def) {
  const i = process.argv.indexOf(flag);
  return i >= 0 && i + 1 < process.argv.length ? process.argv[i + 1] : def;
}
const out = arg("--out", "preview.html");
const stagger = Number(arg("--stagger", 90));
const bg = arg("--bg", "#faf7f4");
// "breath" (default): draw on once, then loop only the idle breath segment.
// "full": loop the entire timeline, so the draw-on repeats every cycle.
const loopMode = arg("--loop", "breath");
if (loopMode !== "breath" && loopMode !== "full") {
  console.error(`preview: --loop must be "breath" or "full" (got "${loopMode}")`);
  process.exit(2);
}
const files = process.argv
  .slice(2)
  .filter((a) => a.endsWith(".json") && !a.startsWith("--"));
if (!files.length) {
  console.error("preview: pass one or more *.json Lottie files");
  process.exit(2);
}

const data = {};
for (const f of files) {
  const name = basename(f).replace(/\.(lottie\.)?json$/, "");
  data[name] = readFileSync(f, "utf8");
}

const tiles = Object.keys(data)
  .map(
    (n) =>
      `<div class="tile"><div class="stage"><div class="anim" data-n="${n}"></div></div>` +
      `<div class="cap"><b>${n}</b></div>` +
      `<button class="replay" data-n="${n}">↻ replay</button></div>`,
  )
  .join("");

const html = `<!doctype html><html><head><meta charset="utf-8"><title>lineart-lottie preview</title><style>
*{margin:0;padding:0;box-sizing:border-box}body{font-family:-apple-system,"Segoe UI",sans-serif;background:${bg};padding:30px;color:#2a2320}
h1{font-size:18px;margin-bottom:4px}.sub{font-size:12px;color:#8a807a;margin-bottom:16px}
.row{display:flex;gap:18px;flex-wrap:wrap}.tile{width:176px}
.stage{width:176px;height:176px;border-radius:20px;background:radial-gradient(120% 120% at 50% 30%,#fbfdfe,#eef4f6 60%,#f4ece4);box-shadow:inset 0 0 0 1px rgba(0,0,0,.04);display:flex;align-items:center;justify-content:center}
.anim{width:132px;height:132px}.cap{font-size:12px;text-align:center;margin-top:9px}.cap b{font-weight:650}
.replay{display:block;margin:5px auto 0;font-size:11px;color:#9a8f88;background:none;border:none;cursor:pointer}
</style></head><body>
<h1>lineart-lottie preview</h1>
<div class="sub">${loopMode === "full" ? "Whole timeline <b>looping</b> — redraws every cycle" : "Draw-on once, then <b>seamless breath loop</b>"}. Rendered with lottie-web.</div>
<div class="row">${tiles}</div>
<script src="${LOTTIE_CDN}"></script>
<script>window.D=${JSON.stringify(data)};</script>
<script>
const anims={};let seq=0;const MODE=${JSON.stringify(loopMode)};
function mount(el){
  const name=el.dataset.n;
  const d=JSON.parse(window.D[name]);
  const OP=d.op;
  const idle=((d.markers||[]).find(m=>m.cm==='idle')||{}).tm||0;
  const a=lottie.loadAnimation({container:el,renderer:'svg',loop:false,autoplay:false,animationData:d});
  let looping=false;
  function start(){
    looping=false;
    a.loop = MODE==='full';                 // full => lottie-web loops the whole timeline natively
    a.playSegments([0,OP],true);            // draw-on from the start
  }
  a.addEventListener('DOMLoaded',()=>{ setTimeout(start, (seq++)*${stagger}); });
  a.addEventListener('complete',()=>{ if(MODE==='full'||looping)return; looping=true; a.loop=true; a.playSegments([idle,OP],true); });
  anims[name]={a,start};
}
document.querySelectorAll('.anim').forEach(mount);
document.querySelectorAll('.replay').forEach(b=>b.onclick=()=>anims[b.dataset.n].start());
</script></body></html>`;

writeFileSync(out, html);
console.log(`wrote ${out}  (${Object.keys(data).length} motifs; lottie-web from ${LOTTIE_CDN})`);
