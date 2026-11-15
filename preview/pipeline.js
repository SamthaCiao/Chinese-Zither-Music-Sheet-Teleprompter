/**
 * 谱图 → 黑底绿字分屏。
 * 竖图整页保留；只有横图才按中间空白竖缝拆成左右两页。
 * 同一页里所有行共用左右边界，避免左右手各自裁白后对不齐。
 * 只保留接近主墨色的像素，不按连通域挖掉笔画（连音线、下划线留得住）。
 */

const SW = 480;
const SH = 352;
const PAD = 10;
const GAP = 7;
const MAX_W = 900;
const MAX_H = 4000;
const INK_Q = 48;
const INK_SPAN = 512;

function layoutKind(w, h) {
  if (w > h * 1.08) return 'landscape';
  if (h > w * 2.35) return 'long';
  return 'portrait';
}

function downscale(rgba, w, h) {
  const scale = Math.min(1, MAX_W / w, MAX_H / h);
  if (scale === 1) return { rgba, w, h, scale: 1 };
  const nw = Math.max(1, Math.round(w * scale));
  const nh = Math.max(1, Math.round(h * scale));
  const out = new Uint8ClampedArray(nw * nh * 4);
  for (let y = 0; y < nh; y++) {
    const fy = Math.min(h - 1, (y + 0.5) / scale - 0.5);
    const y0 = fy | 0;
    const y1 = Math.min(h - 1, y0 + 1);
    const ty = fy - y0;
    for (let x = 0; x < nw; x++) {
      const fx = Math.min(w - 1, (x + 0.5) / scale - 0.5);
      const x0 = fx | 0;
      const x1 = Math.min(w - 1, x0 + 1);
      const tx = fx - x0;
      const di = (y * nw + x) * 4;
      for (let c = 0; c < 4; c++) {
        const a00 = rgba[(y0 * w + x0) * 4 + c];
        const a01 = rgba[(y0 * w + x1) * 4 + c];
        const a10 = rgba[(y1 * w + x0) * 4 + c];
        const a11 = rgba[(y1 * w + x1) * 4 + c];
        out[di + c] = (a00 * (1 - tx) + a01 * tx) * (1 - ty) + (a10 * (1 - tx) + a11 * tx) * ty;
      }
    }
  }
  return { rgba: out, w: nw, h: nh, scale };
}

function probeInk(px) {
  const lh = new Uint32Array(256);
  for (let i = 0; i < px.length; i += 4) {
    lh[(px[i] * 299 + px[i + 1] * 587 + px[i + 2] * 114) / 1000 | 0]++;
  }
  let bgL = 255;
  let top = 0;
  for (let l = 0; l < 256; l++) if (lh[l] > top) { top = lh[l]; bgL = l; }
  const cut = bgL - Math.max(14, bgL * 0.12);
  const den = Math.max(1, bgL * 0.65);
  const hist = new Float32Array(INK_Q * INK_Q);
  for (let i = 0; i < px.length; i += 4) {
    const r = px[i];
    const g = px[i + 1];
    const b = px[i + 2];
    const L = (r * 299 + g * 587 + b * 114) / 1000;
    if (L >= cut) continue;
    const wt = Math.min(1, (bgL - L) / den);
    if (wt < 0.05) continue;
    const ix = ((r - g + 256) * INK_Q / INK_SPAN) | 0;
    const iy = ((g - b + 256) * INK_Q / INK_SPAN) | 0;
    if (ix < 0 || iy < 0 || ix >= INK_Q || iy >= INK_Q) continue;
    hist[iy * INK_Q + ix] += wt;
  }
  const work = hist.slice();
  const peaks = [];
  for (let k = 0; k < 3; k++) {
    let bi = -1;
    let bv = 0;
    for (let i = 0; i < work.length; i++) if (work[i] > bv) { bv = work[i]; bi = i; }
    if (bi < 0 || bv <= 0) break;
    const cx = bi % INK_Q;
    const cy = (bi / INK_Q) | 0;
    peaks.push({ u: (cx + 0.5) * INK_SPAN / INK_Q - 256, v: (cy + 0.5) * INK_SPAN / INK_Q - 256 });
    for (let dy = -2; dy <= 2; dy++) for (let dx = -2; dx <= 2; dx++) {
      const nx = cx + dx;
      const ny = cy + dy;
      if (nx >= 0 && ny >= 0 && nx < INK_Q && ny < INK_Q) work[ny * INK_Q + nx] = 0;
    }
  }
  if (!peaks.length) return { bgL, inks: [{ u: 0, v: 0, Lk: 60, frac: 1, n: 1 }] };
  const acc = peaks.map(() => ({ n: 0, su: 0, sv: 0, ls: [] }));
  for (let i = 0; i < px.length; i += 4) {
    const r = px[i];
    const g = px[i + 1];
    const b = px[i + 2];
    const L = (r * 299 + g * 587 + b * 114) / 1000;
    if (L >= cut) continue;
    const u = r - g;
    const v = g - b;
    let bi = 0;
    let bd = 1e9;
    for (let k = 0; k < peaks.length; k++) {
      const d = (u - peaks[k].u) ** 2 + (v - peaks[k].v) ** 2;
      if (d < bd) { bd = d; bi = k; }
    }
    if (bd > 40 * 40) continue;
    const a = acc[bi];
    a.n++;
    a.su += u;
    a.sv += v;
    if (a.ls.length < 4000) a.ls.push(L);
  }
  const inks = [];
  let totalN = 0;
  acc.forEach((a) => { totalN += a.n; });
  acc.forEach((a) => {
    if (a.n < Math.max(30, totalN * 0.05)) return;
    a.ls.sort((x, y) => x - y);
    const Lk = a.ls.length ? a.ls[Math.floor(a.ls.length * 0.25)] : 60;
    if (Lk > bgL - 45) return;
    inks.push({ u: a.su / a.n, v: a.sv / a.n, Lk, frac: a.n / totalN, n: a.n });
  });
  if (!inks.length) inks.push({ u: 0, v: 0, Lk: Math.max(30, bgL - 120), frac: 1, n: 1 });
  inks.sort((x, y) => y.n - x.n);
  const out = [inks[0]];
  const gap = bgL - inks[0].Lk;
  for (let k = 1; k < inks.length && out.length < 2; k++) {
    const d = Math.hypot(inks[k].u - out[0].u, inks[k].v - out[0].v);
    if (d < 26) continue;
    if (inks[k].frac < inks[0].frac * 0.10) continue;
    if (inks[k].Lk > inks[0].Lk + gap * 0.35) continue;
    out.push(inks[k]);
  }
  return { bgL, inks: out };
}

function buildInkMask(px, w, h, bgL, inks) {
  const A = new Uint8Array(w * h);
  const use = inks.map((k) => {
    const kr = (2 * k.u + k.v) / 3;
    const kg = (-k.u + k.v) / 3;
    const kb = (-k.u - 2 * k.v) / 3;
    return { kr, kg, kb, mag2: kr * kr + kg * kg + kb * kb, Lk: k.Lk };
  });
  const DC = 30 * 30;
  const RANGE = Math.max(12, bgL * 0.9);
  const deepCut = use[0].Lk + (bgL - use[0].Lk) * 0.22;
  let pinkKept = 0;
  let darkKept = 0;
  let kept = 0;
  for (let i = 0, p = 0; i < px.length; i += 4, p++) {
    const r = px[i];
    const g = px[i + 1];
    const b = px[i + 2];
    const L = (r * 299 + g * 587 + b * 114) / 1000;
    if (L >= bgL - 3) continue;
    const cr = r - L;
    const cg = g - L;
    const cb = b - L;
    let match = 0;
    for (let k = 0; k < use.length; k++) {
      const m = use[k];
      let res2;
      if (m.mag2 < 100) res2 = cr * cr + cg * cg + cb * cb;
      else {
        const t = (cr * m.kr + cg * m.kg + cb * m.kb) / m.mag2;
        if (t < 0.05) continue;
        const er = cr - t * m.kr;
        const eg = cg - t * m.kg;
        const eb = cb - t * m.kb;
        res2 = er * er + eg * eg + eb * eb;
      }
      const mm = 1 - res2 / DC;
      if (mm > match) match = mm;
    }
    // 彩色水印即使偏暗，也不因“够黑”被强行收进音符。
    if (match <= 0.35) continue;
    let depth = (bgL - L) / RANGE;
    if (depth > 1) depth = 1;
    if (depth <= 0) continue;
    const v = Math.min(1, depth * match) ** 1.15 * 255 | 0;
    A[p] = v;
    if (v > 26) {
      kept++;
      const pink = r > 150 && r > g + 25 && r > b + 15;
      if (pink && L > deepCut) pinkKept++;
      if (L < 90) darkKept++;
    }
  }
  let n2 = 0;
  const bh = new Uint32Array(256);
  for (let p = 0; p < A.length; p++) if (A[p] > 26) { bh[A[p]]++; n2++; }
  let mode = 255;
  if (n2 > 500) {
    let accn = 0;
    for (let i = 255; i >= 0; i--) { accn += bh[i]; if (accn >= n2 * 0.15) { mode = i; break; } }
  }
  return { A, mode, pinkKept, darkKept, kept };
}

function detectVSeams(dark, w, h) {
  const colCnt = new Uint32Array(w);
  for (let y = 0; y < h; y++) {
    const b = y * w;
    for (let x = 0; x < w; x++) if (dark[b + x]) colCnt[x]++;
  }
  const floor = Math.max(2, h * 0.004);
  const minSw = Math.max(18, w * 0.06);
  const seams = [];
  let inS = false;
  let st = 0;
  for (let x = 0; x <= w; x++) {
    const v = x < w ? colCnt[x] <= floor : false;
    if (v) { if (!inS) { inS = true; st = x; } }
    else if (inS) { inS = false; if (x - st >= minSw) seams.push([st, x]); }
  }
  const pages = [];
  let prev = 0;
  for (const [a, b] of seams) {
    if (a - prev >= w * 0.28) pages.push([prev, a]);
    prev = b;
  }
  if (w - prev >= w * 0.28) pages.push([prev, w]);
  return pages.length > 1 ? pages : [[0, w]];
}

function splitRows(dark, w, h, x0, x1) {
  const pw = x1 - x0;
  const cnt = new Uint32Array(h);
  for (let y = 0; y < h; y++) {
    let c = 0;
    const b = y * w;
    for (let x = x0; x < x1; x++) if (dark[b + x]) c++;
    cnt[y] = c;
  }
  const noiseFloor = Math.max(2, pw * 0.001);
  let isC = new Uint8Array(h);
  for (let y = 0; y < h; y++) isC[y] = (cnt[y] > noiseFloor && cnt[y] <= pw * 0.70) ? 1 : 0;
  const filled = new Uint8Array(h);
  for (let y = 0; y < h; y++) {
    if (isC[y]) { filled[y] = 1; continue; }
    let up = -1;
    let dn = -1;
    for (let k = 1; k <= 2 && up < 0; k++) if (y - k >= 0 && isC[y - k]) up = k;
    for (let k = 1; k <= 2 && dn < 0; k++) if (y + k < h && isC[y + k]) dn = k;
    if (up > 0 && dn > 0) filled[y] = 1;
  }
  const raw = [];
  let inB = false;
  let st = 0;
  for (let y = 0; y <= h; y++) {
    const v = y < h ? filled[y] : 0;
    if (v) { if (!inB) { inB = true; st = y; } }
    else if (inB) { inB = false; raw.push([st, y]); }
  }
  const minH = Math.max(4, h * 0.004);
  const bl = raw.filter(([a, b]) => b - a >= minH);
  const avgH = bl.length ? bl.reduce((s, b) => s + (b[1] - b[0]), 0) / bl.length : 0;
  const mg = avgH * 0.35 * 0.9;
  const merged = [];
  for (const b of bl) {
    if (merged.length && b[0] - merged[merged.length - 1][1] < mg) merged[merged.length - 1][1] = b[1];
    else merged.push([b[0], b[1]]);
  }
  return merged;
}

function buildScreens(blocks) {
  const usable = SH - PAD * 2;
  let maxW = 1;
  blocks.forEach((b) => { maxW = Math.max(maxW, b.x1 - b.x0); });
  const s0 = (SW - PAD * 2) / maxW;
  const out = [];
  let group = [];
  let acc = 0;
  blocks.forEach((b, i) => {
    const hh = (b.y1 - b.y0) * s0;
    if (group.length && acc + hh + GAP > usable) {
      out.push(group);
      group = [];
      acc = 0;
    }
    group.push(i);
    acc += hh + GAP;
  });
  if (group.length) out.push(group);
  return out;
}

function analyzeImage(rgba, width, height, name) {
  const src = downscale(rgba, width, height);
  const px = src.rgba;
  const w = src.w;
  const h = src.h;
  const luma = new Uint8Array(w * h);
  for (let i = 0; i < w * h; i++) {
    const p = i * 4;
    luma[i] = (px[p] * 299 + px[p + 1] * 587 + px[p + 2] * 114) / 1000 | 0;
  }
  const kind = layoutKind(width, height);
  const prof = probeInk(px);
  const built = buildInkMask(px, w, h, prof.bgL, prof.inks);
  const cutIn = Math.max(2, built.mode * 0.12);
  const A = new Uint8Array(built.A.length);
  for (let i = 0; i < built.A.length; i++) {
    const v = built.A[i];
    A[i] = v <= cutIn ? 0 : Math.min(255, (v - cutIn) / Math.max(1, built.mode - cutIn) * built.mode) | 0;
  }
  const dark = new Uint8Array(w * h);
  for (let i = 0; i < A.length; i++) if (A[i] > 18) dark[i] = 1;
  const pages = kind === 'landscape' ? detectVSeams(dark, w, h) : [[0, w]];
  const blocks = [];
  pages.forEach((pg, pi) => {
    const rows = splitRows(dark, w, h, pg[0], pg[1]);
    if (!rows.length) return;
    let pageMin = pg[1];
    let pageMax = pg[0] - 1;
    for (let y = 0; y < h; y++) {
      const base = y * w;
      for (let x = pg[0]; x < pg[1]; x++) {
        if (dark[base + x]) {
          if (x < pageMin) pageMin = x;
          if (x > pageMax) pageMax = x;
        }
      }
    }
    if (pageMin > pageMax) { pageMin = pg[0]; pageMax = pg[1] - 1; }
    const gaps = [];
    for (let i = 1; i < rows.length; i++) gaps.push(rows[i][0] - rows[i - 1][1]);
    gaps.sort((a, b) => a - b);
    const med = gaps.length ? gaps[(gaps.length / 2) | 0] : 0;
    const thr = Math.max(3 / src.scale, med * 0.55);
    const sets = [[rows[0]]];
    for (let i = 1; i < rows.length; i++) {
      if (rows[i][0] - rows[i - 1][1] < thr) sets[sets.length - 1].push(rows[i]);
      else sets.push([rows[i]]);
    }
    let prevY1 = 0;
    sets.forEach((set, si) => {
      const a0 = set[0][0];
      const b0 = set[set.length - 1][1];
      const gh = b0 - a0;
      const pad = Math.min(gh * 0.14, 44 / src.scale);
      const nextA = si < sets.length - 1 ? sets[si + 1][0][0] : h;
      const y0 = Math.max(prevY1 + (a0 - prevY1) * 0.35, a0 - pad);
      const y1 = Math.min(nextA - (nextA - b0) * 0.35, b0 + pad);
      prevY1 = b0;
      blocks.push({
        x0: Math.max(0, (pageMin - 3) / src.scale),
        x1: Math.min(width, (pageMax + 4) / src.scale),
        y0: Math.max(0, y0 / src.scale),
        y1: Math.min(height, y1 / src.scale),
        pi
      });
    });
  });
  return {
    name: name || '',
    srcW: width,
    srcH: height,
    kind,
    pageCount: pages.length,
    blocks,
    mask: A,
    maskW: w,
    maskH: h,
    scale: src.scale,
    luma,
    lumaW: w,
    lumaH: h,
    bgL: prof.bgL,
    ink: prof.inks[0],
    kept: built.kept,
    pinkKept: built.pinkKept,
    darkKept: built.darkKept,
    warning: kind !== 'landscape' && pages.length === 1
      ? ''
      : (pages.length > 1 ? '横图已按空白竖缝拆成 ' + pages.length + ' 页' : '')
  };
}

function combineAnalyses(list) {
  const blocks = [];
  list.forEach((an, img) => {
    an.blocks.forEach((b) => blocks.push({ ...b, img }));
  });
  return { blocks, screens: buildScreens(blocks), images: list };
}

function renderScreen(pack, index) {
  const rgba = new Uint8ClampedArray(SW * SH * 4);
  const sc = pack.screens[index] || [];
  if (!sc.length) return { rgba, w: SW, h: SH };
  let maxW = 1;
  pack.blocks.forEach((b) => { maxW = Math.max(maxW, b.x1 - b.x0); });
  const s0 = (SW - PAD * 2) / maxW;
  const usable = SH - PAD * 2;
  const items = sc.map((i) => {
    const b = pack.blocks[i];
    return { b, w: (b.x1 - b.x0) * s0, h: (b.y1 - b.y0) * s0 };
  });
  const sumH = items.reduce((s, it) => s + it.h, 0) + GAP * Math.max(0, items.length - 1);
  const fit = Math.min(1, usable / Math.max(1, sumH));
  let y = PAD + (usable - sumH * fit) / 2;
  if (y < PAD) y = PAD;
  items.forEach((it) => {
    const dw = Math.max(1, Math.round(it.w * fit));
    const dh = Math.max(1, Math.round(it.h * fit));
    const dx = Math.round((SW - dw) / 2);
    const dy = Math.round(y);
    const an = pack.images[it.b.img];
    const A = an.mask;
    const w = an.maskW;
    const h = an.maskH;
    const ks = an.scale;
    const sx = Math.max(0, it.b.x0 * ks);
    const sy = Math.max(0, it.b.y0 * ks);
    const sw = Math.max(1, (it.b.x1 - it.b.x0) * ks);
    const sh = Math.max(1, (it.b.y1 - it.b.y0) * ks);
    for (let py = 0; py < dh; py++) {
      const yy = dy + py;
      if (yy < 0 || yy >= SH) continue;
      const fy = Math.min(sh - 0.001, Math.max(0, (py + 0.5) / dh * sh - 0.5));
      const y0i = fy | 0;
      const ty = fy - y0i;
      const r0 = Math.min(h - 1, (y0i + sy) | 0);
      const r1 = Math.min(h - 1, r0 + 1);
      for (let pxl = 0; pxl < dw; pxl++) {
        const xx = dx + pxl;
        if (xx < 0 || xx >= SW) continue;
        const fx = Math.min(sw - 0.001, Math.max(0, (pxl + 0.5) / dw * sw - 0.5));
        const x0i = fx | 0;
        const tx = fx - x0i;
        const c0 = Math.min(w - 1, (x0i + sx) | 0);
        const c1 = Math.min(w - 1, c0 + 1);
        const a00 = A[r0 * w + c0];
        const a01 = A[r0 * w + c1];
        const a10 = A[r1 * w + c0];
        const a11 = A[r1 * w + c1];
        const v = (a00 * (1 - tx) + a01 * tx) * (1 - ty) + (a10 * (1 - tx) + a11 * tx) * ty;
        if (v > 8) {
          const di = (yy * SW + xx) * 4;
          rgba[di] = 0x3d;
          rgba[di + 1] = 0xff;
          rgba[di + 2] = 0x5c;
          rgba[di + 3] = v >= 252 ? 255 : v | 0;
        }
      }
    }
    y += dh + GAP * fit;
  });
  return { rgba, w: SW, h: SH };
}

globalThis.ScorePipeline = { layoutKind, analyzeImage, combineAnalyses, renderScreen };
