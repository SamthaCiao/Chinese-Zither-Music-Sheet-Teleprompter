/**
 * 从谱图像素里读右手那一行的简谱数字，再按小节线分成小节。0 是休止，不拿去对音高。
 * 字形规则在《发如雪》第一页第一行对过。翻页用每一屏最后一小节；这串音若在本屏前面已经能对上，就再往前并一小节。
 */

export function maskFromRGBA(data, w, h) {
  const dark = new Uint8Array(w * h);
  for (let i = 0, p = 0; i < w * h; i++, p += 4) {
    const r = data[p], g = data[p + 1], b = data[p + 2];
    if (r > g + 25 && r > b + 10 && r > 140) continue;
    if ((r + g + b) / 3 < 90) dark[i] = 1;
  }
  return dark;
}

function holeCount(ink, bw, bh) {
  const seen = new Uint8Array(bw * bh);
  let n = 0;
  for (let y = 0; y < bh; y++) {
    for (let x = 0; x < bw; x++) {
      const p = y * bw + x;
      if (ink[p] || seen[p]) continue;
      const stack = [x, y];
      seen[p] = 1;
      let touch = x === 0 || y === 0 || x === bw - 1 || y === bh - 1;
      while (stack.length) {
        const cy = stack.pop();
        const cx = stack.pop();
        const nbs = [cx - 1, cy, cx + 1, cy, cx, cy - 1, cx, cy + 1];
        for (let k = 0; k < nbs.length; k += 2) {
          const nx = nbs[k], ny = nbs[k + 1];
          if (nx < 0 || ny < 0 || nx >= bw || ny >= bh) continue;
          const q = ny * bw + nx;
          if (ink[q] || seen[q]) continue;
          if (nx === 0 || ny === 0 || nx === bw - 1 || ny === bh - 1) touch = true;
          seen[q] = 1;
          stack.push(nx, ny);
        }
      }
      if (!touch) n++;
    }
  }
  return n;
}

function classify(bw, bh, pts) {
  if (bw <= 11) return '1';
  const g = [];
  for (let i = 0; i < 12; i++) g.push([0, 0, 0, 0, 0, 0, 0, 0, 0]);
  let minX = pts[0], minY = pts[1];
  for (let i = 0; i < pts.length; i += 2) {
    if (pts[i] < minX) minX = pts[i];
    if (pts[i + 1] < minY) minY = pts[i + 1];
  }
  const ink = new Uint8Array(bw * bh);
  for (let i = 0; i < pts.length; i += 2) {
    const x = pts[i] - minX, y = pts[i + 1] - minY;
    ink[y * bw + x] = 1;
    const gx = Math.min(8, (x / bw * 9) | 0);
    const gy = Math.min(11, (y / bh * 12) | 0);
    g[gy][gx] = 1;
  }
  const box = (y0, y1, x0, x1) => {
    let s = 0;
    for (let y = y0; y < y1; y++) for (let x = x0; x < x1; x++) s += g[y][x];
    return s;
  };
  const rowSum = (y, x0, x1) => {
    let s = 0;
    for (let x = x0; x < x1; x++) s += g[y][x];
    return s;
  };
  let openRight = false;
  for (let y = 2; y < 5; y++) {
    if (rowSum(y, 0, 4) >= 2 && rowSum(y, 6, 9) === 0) openRight = true;
  }
  const hole = holeCount(ink, bw, bh);
  if (hole >= 1 && openRight) return '6';
  if (hole >= 1) return '0';
  let spans = false;
  for (let y = 3; y < 7; y++) if (rowSum(y, 0, 9) >= 7) spans = true;
  const upperLeft = box(2, 5, 0, 4);
  if (spans && upperLeft >= 3 && box(2, 4, 6, 9) <= 1) return '5';
  const bottomFull = rowSum(10, 0, 9) >= 7 && rowSum(11, 0, 9) >= 7;
  let mid = 0;
  for (let y = 4; y < 9; y++) mid += rowSum(y, 0, 9);
  if (bottomFull && mid <= 22) return '2';
  if (box(0, 12, 6, 9) >= box(0, 12, 0, 3)) return '3';
  return '7';
}

function readBand(dark, w, y0, y1) {
  const bh0 = y1 - y0;
  const seen = new Uint8Array(w * bh0);
  const found = [];
  for (let yy = y0; yy < y1; yy++) {
    for (let xx = 0; xx < w; xx++) {
      if (!dark[yy * w + xx] || seen[(yy - y0) * w + xx]) continue;
      const stack = [xx, yy];
      seen[(yy - y0) * w + xx] = 1;
      const pts = [];
      let minX = xx, maxX = xx, minY = yy, maxY = yy, n = 0;
      while (stack.length) {
        const cy = stack.pop();
        const cx = stack.pop();
        pts.push(cx, cy);
        n++;
        if (cx < minX) minX = cx;
        if (cx > maxX) maxX = cx;
        if (cy < minY) minY = cy;
        if (cy > maxY) maxY = cy;
        const nbs = [cx - 1, cy, cx + 1, cy, cx, cy - 1, cx, cy + 1];
        for (let k = 0; k < 8; k += 2) {
          const nx = nbs[k], ny = nbs[k + 1];
          if (nx < 0 || nx >= w || ny < y0 || ny >= y1) continue;
          const q = (ny - y0) * w + nx;
          if (!dark[ny * w + nx] || seen[q]) continue;
          seen[q] = 1;
          stack.push(nx, ny);
        }
      }
      if (n < 25) continue;
      const bw = maxX - minX + 1, bh = maxY - minY + 1;
      if (bh < 14 || bw > 40 || bh > 40 || bw < 6) continue;
      found.push({ x: minX, bw, bh, pts });
    }
  }
  found.sort((a, b) => a.x - b.x);
  let text = '';
  const marks = [];
  for (let i = 0; i < found.length; i++) {
    const ch = classify(found[i].bw, found[i].bh, found[i].pts);
    text += ch;
    marks.push({ x: found[i].x, bw: found[i].bw, ch });
  }
  return { text, marks };
}

function pickBars(score, thr, marks) {
  const raw = [];
  const w = score.length;
  let x = 0;
  while (x < w) {
    if (score[x] < thr) { x++; continue; }
    let x1 = x + 1;
    while (x1 < w && score[x1] >= thr * 0.62) x1++;
    const bw = x1 - x;
    if (bw >= 1 && bw <= 8) {
      let peak = 0;
      let px = x;
      for (let i = x; i < x1; i++) if (score[i] > peak) { peak = score[i]; px = i; }
      let inside = false;
      for (let i = 0; i < marks.length; i++) {
        const m = marks[i];
        if (px >= m.x - 2 && px <= m.x + m.bw + 2) { inside = true; break; }
      }
      if (!inside && peak >= thr) raw.push(px);
    }
    x = Math.max(x1, x + 1);
  }
  const bars = [];
  raw.forEach((c) => {
    if (!bars.length || c - bars[bars.length - 1] > 16) bars.push(c);
  });
  if (bars.length > Math.max(8, marks.length * 0.7)) return [];
  return bars;
}

/** 右手带里又高又窄的竖线。手写谱的小节线往往只露出数字上下两端，再靠两端补一次。 */
function barCenters(dark, w, y0, y1, marks) {
  const h = y1 - y0;
  if (h < 16) return [];
  const col = new Int32Array(w);
  for (let y = y0; y < y1; y++) {
    const row = y * w;
    for (let x = 0; x < w; x++) col[x] += dark[row + x];
  }
  const primary = pickBars(col, Math.max(8, h * 0.42), marks);
  if (primary.length >= 3) return primary;
  const tip = Math.max(5, Math.round(h * 0.16));
  const score = new Int32Array(w);
  for (let x = 0; x < w; x++) {
    let a = 0;
    let b = 0;
    for (let y = y0; y < y0 + tip && y < y1; y++) a += dark[y * w + x];
    for (let y = Math.max(y0, y1 - tip); y < y1; y++) b += dark[y * w + x];
    if (a >= tip * 0.45 && b >= tip * 0.45) score[x] = a + b;
  }
  const tips = pickBars(score, Math.max(4, tip * 0.85), marks);
  return tips.length >= 3 ? tips : primary;
}

function chunkGlyphs(text, size) {
  const parts = [];
  let i = text.length;
  const n = Math.max(4, size);
  while (i > 0) {
    const a = Math.max(0, i - n);
    parts.unshift(text.slice(a, i));
    i = a;
  }
  return parts;
}

function groupByBars(marks, bars) {
  if (!marks.length) return [];
  if (!bars.length) return [marks.map((m) => m.ch).join('')];
  const bins = [];
  for (let i = 0; i < bars.length + 1; i++) bins.push([]);
  for (let i = 0; i < marks.length; i++) {
    const cx = marks[i].x + marks[i].bw / 2;
    let b = 0;
    while (b < bars.length && cx > bars[b]) b++;
    bins[b].push(marks[i].ch);
  }
  const measures = [];
  bins.forEach((bin) => {
    if (bin.length) measures.push(bin.join(''));
  });
  return measures.length ? measures : [marks.map((m) => m.ch).join('')];
}

/** 右手行：后面紧跟着一行左手的那一条。 */
export function readMelody(dark, w, h) {
  const proj = new Int32Array(h);
  for (let y = 0; y < h; y++) {
    let s = 0;
    const row = y * w;
    for (let x = 0; x < w; x++) s += dark[row + x];
    proj[y] = s;
  }
  const bands = [];
  let inb = false, a = 0;
  for (let y = 0; y < h; y++) {
    if (proj[y] > 30 && !inb) { a = y; inb = true; }
    else if (proj[y] < 8 && inb) {
      if (y - a > 12) bands.push([a, y]);
      inb = false;
    }
  }
  const rows = [];
  for (let i = 0; i < bands.length; i++) {
    const y0 = bands[i][0], y1 = bands[i][1];
    if (y0 < Math.min(120, h * 0.07) || y1 - y0 < 40) continue;
    const nxt = i + 1 < bands.length ? bands[i + 1][0] - y1 : 999;
    if (nxt > 110) continue;
    const band = readBand(dark, w, y0, y1);
    if (!band.text) continue;
    const bars = barCenters(dark, w, y0, y1, band.marks);
    let measures = groupByBars(band.marks, bars);
    if (bars.length < 2 && band.text.length > 8) measures = chunkGlyphs(band.text, 6);
    rows.push({ y0, y1, notes: band.text, measures, bars: bars.length });
  }
  return rows;
}

const DEG = { 1: 0, 2: 2, 3: 4, 4: 5, 5: 7, 6: 9, 7: 11 };

/** 休止符 0 不算音。1 的音高按 keyPc，D 调是 2，落在 MIDI 62。只留音级，不看八度点。 */
export function midisOf(digits, keyPc) {
  const out = [];
  const s = digits || '';
  for (let i = 0; i < s.length; i++) {
    const d = DEG[s[i]];
    if (d == null) continue;
    out.push(60 + keyPc + d);
  }
  return out;
}

function closesAt(seq, phrase, end) {
  const n = phrase.length;
  if (end < n - 1 || seq[end] !== phrase[n - 1]) return false;
  const minStart = Math.max(0, end - n);
  for (let s = minStart; s <= end; s++) {
    let i = s;
    let k = 0;
    let extras = 0;
    while (k < n && i <= end) {
      if (seq[i] === phrase[k]) {
        if (k === n - 1) return i === end;
        i++;
        k++;
      } else if (extras < 1 && i < end) {
        extras++;
        i++;
      } else break;
    }
  }
  return false;
}

/** 这一小节若在本屏前面，连「中间夹一个杂音」也能对上，就不算独特。 */
function occursBefore(melody, phrase) {
  const n = phrase.length;
  if (n < 1 || melody.length <= n) return false;
  const limit = melody.length - n;
  for (let end = n - 1; end < limit; end++) {
    if (closesAt(melody, phrase, end)) return true;
  }
  return false;
}

/**
 * 翻页认的是这一屏最后一小节，不是整页，也不是开头那一两个音。
 * 这一小节不足 4 个音，或这串音在本屏前面已经出现过，就再往前并一小节。
 */
export function edgeFromMeasures(measures, keyPc) {
  const groups = [];
  (measures || []).forEach((m) => {
    const midis = midisOf(m, keyPc);
    if (midis.length) groups.push(midis);
  });
  const melody = [];
  groups.forEach((g) => melody.push.apply(melody, g));
  if (!groups.length) return { phrase: [], melody, take: 0 };
  let take = 1;
  let phrase = groups[groups.length - 1].slice();
  while (take < groups.length && (phrase.length < 4 || occursBefore(melody, phrase))) {
    take++;
    phrase = [];
    groups.slice(groups.length - take).forEach((g) => phrase.push.apply(phrase, g));
  }
  return { phrase, melody, take };
}

/** 每屏 lines 行。休止符 0 不进入要对的音。1 的音高按 keyPc，D 调是 2。 */
export function screensFromRows(rows, lines, keyPc) {
  const out = [];
  const n = Math.max(1, lines | 0);
  for (let i = 0; i < rows.length; i += n) {
    const midis = [];
    const chunk = rows.slice(i, i + n);
    for (let r = 0; r < chunk.length; r++) {
      const s = typeof chunk[r] === 'string' ? chunk[r] : chunk[r].notes;
      for (let k = 0; k < s.length; k++) {
        const d = DEG[s[k]];
        if (d == null) continue;
        midis.push(60 + keyPc + d);
      }
    }
    out.push(midis);
  }
  return out;
}
