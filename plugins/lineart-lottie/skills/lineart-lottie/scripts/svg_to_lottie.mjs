// Minimal SVG path `d` -> Lottie shape path converter (M/m L/l H/h V/v C/c S/s Q/q T/t Z/z).
// Returns { c: bool, v: [[x,y]], i: [[dx,dy]], o: [[dx,dy]] } per subpath (Lottie tangents are vertex-relative).
export function parsePath(d) {
  const toks = d.match(/[a-zA-Z]|-?\d*\.?\d+(?:e-?\d+)?/g) || [];
  let pi = 0;
  const num = () => parseFloat(toks[pi++]);
  const subpaths = [];
  let cur = null; // current subpath
  let px = 0,
    py = 0; // current point
  let startx = 0,
    starty = 0;
  let prevCtrl = null; // for S/T smoothing
  let lastCmd = "";

  function newSub(x, y) {
    cur = { c: false, v: [], i: [], o: [] };
    subpaths.push(cur);
    cur.v.push([x, y]);
    cur.i.push([0, 0]);
    cur.o.push([0, 0]);
    px = startx = x;
    py = starty = y;
  }
  function lineTo(x, y) {
    cur.v.push([x, y]);
    cur.i.push([0, 0]);
    cur.o.push([0, 0]);
    px = x;
    py = y;
    prevCtrl = null;
  }
  // cubic from current (px,py) via control c1,c2 to end
  function cubicTo(c1x, c1y, c2x, c2y, ex, ey) {
    const last = cur.v.length - 1;
    cur.o[last] = [c1x - px, c1y - py]; // out handle of previous vertex
    cur.v.push([ex, ey]);
    cur.i.push([c2x - ex, c2y - ey]); // in handle of new vertex
    cur.o.push([0, 0]);
    px = ex;
    py = ey;
    prevCtrl = [c2x, c2y];
  }
  function quadTo(qx, qy, ex, ey) {
    // convert quadratic control -> cubic
    const c1x = px + (2 / 3) * (qx - px),
      c1y = py + (2 / 3) * (qy - py);
    const c2x = ex + (2 / 3) * (qx - ex),
      c2y = ey + (2 / 3) * (qy - ey);
    cubicTo(c1x, c1y, c2x, c2y, ex, ey);
    prevCtrl = [qx, qy]; // store quad ctrl for T
  }

  while (pi < toks.length) {
    let cmd = toks[pi];
    if (/[a-zA-Z]/.test(cmd)) {
      pi++;
      lastCmd = cmd;
    } else {
      cmd = lastCmd === "M" ? "L" : lastCmd === "m" ? "l" : lastCmd;
    } // implicit repeat
    const rel = cmd === cmd.toLowerCase();
    const bx = rel ? px : 0,
      by = rel ? py : 0;
    switch (cmd.toUpperCase()) {
      case "M": {
        const x = num() + bx,
          y = num() + by;
        newSub(x, y);
        break;
      }
      case "L": {
        const x = num() + bx,
          y = num() + by;
        lineTo(x, y);
        break;
      }
      case "H": {
        const x = num() + bx;
        lineTo(x, py);
        break;
      }
      case "V": {
        const y = num() + by;
        lineTo(px, y);
        break;
      }
      case "C": {
        const c1x = num() + bx,
          c1y = num() + by,
          c2x = num() + bx,
          c2y = num() + by,
          ex = num() + bx,
          ey = num() + by;
        cubicTo(c1x, c1y, c2x, c2y, ex, ey);
        break;
      }
      case "S": {
        const c2x = num() + bx,
          c2y = num() + by,
          ex = num() + bx,
          ey = num() + by;
        const c1x = prevCtrl ? 2 * px - prevCtrl[0] : px,
          c1y = prevCtrl ? 2 * py - prevCtrl[1] : py;
        cubicTo(c1x, c1y, c2x, c2y, ex, ey);
        break;
      }
      case "Q": {
        const qx = num() + bx,
          qy = num() + by,
          ex = num() + bx,
          ey = num() + by;
        quadTo(qx, qy, ex, ey);
        break;
      }
      case "T": {
        const ex = num() + bx,
          ey = num() + by;
        const qx = prevCtrl ? 2 * px - prevCtrl[0] : px,
          qy = prevCtrl ? 2 * py - prevCtrl[1] : py;
        quadTo(qx, qy, ex, ey);
        break;
      }
      case "Z": {
        cur.c = true;
        px = startx;
        py = starty;
        prevCtrl = null;
        break;
      }
      default:
        throw new Error("unsupported path cmd: " + cmd);
    }
  }
  return subpaths;
}

// round arrays for compact JSON
export function roundSub(s) {
  const r = (a) => a.map((p) => [+p[0].toFixed(2), +p[1].toFixed(2)]);
  return { c: s.c, v: r(s.v), i: r(s.i), o: r(s.o) };
}
