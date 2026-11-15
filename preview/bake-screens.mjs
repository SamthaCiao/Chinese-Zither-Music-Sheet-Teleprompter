/**
 * 在电脑上把 catalog 里的谱切成眼镜能直接贴的 480×330 图。
 * 分行和墨色沿用 preview/pipeline.js。上屏用原图深浅画绿字，不再在眼镜里算。
 * 每首同时出每页 2 行和每页 3 行。翻页用的是这一屏最后一小节，不是录音。
 *
 * 在 preview 目录运行：node bake-screens.mjs
 */
import fs from 'fs';
import path from 'path';
import vm from 'vm';
import jpeg from 'jpeg-js';
import { maskFromRGBA, readMelody, edgeFromMeasures } from '../aiui-agent/jianpu-read.js';
import { keyPcOf, notesFromEdge, synthPhrase } from './edge-phrase.mjs';

const SW = 480;
const SH = 330;
const PAD = 8;
const GAP = 6;
const root = path.resolve('..');
const catalog = JSON.parse(fs.readFileSync(path.join(root, 'scores', 'catalog.json'), 'utf8'));

const sandbox = { console, globalThis: {} };
vm.createContext(sandbox);
vm.runInContext(fs.readFileSync(path.resolve('pipeline.js'), 'utf8'), sandbox);
const { analyzeImage } = sandbox.globalThis.ScorePipeline;

function givenEdges(song, lines) {
  let bag = song.edges || null;
  if (!bag && song.edgesFile) {
    const file = path.resolve(root, song.edgesFile);
    const data = JSON.parse(fs.readFileSync(file, 'utf8'));
    bag = data.edges || data;
  }
  if (!bag) return null;
  return bag[String(lines)] || null;
}

function renderScreen(images, blocks, indices) {
  const rgba = new Uint8ClampedArray(SW * SH * 4);
  for (let i = 3; i < rgba.length; i += 4) rgba[i] = 255;
  if (!indices.length) return rgba;
  let maxW = 1;
  blocks.forEach((b) => { maxW = Math.max(maxW, b.x1 - b.x0); });
  const s0 = (SW - PAD * 2) / maxW;
  const usable = SH - PAD * 2;
  const items = indices.map((i) => {
    const b = blocks[i];
    return { b, w: (b.x1 - b.x0) * s0, h: (b.y1 - b.y0) * s0 };
  });
  const sumH = items.reduce((s, it) => s + it.h, 0) + GAP * Math.max(0, items.length - 1);
  const fit = Math.min(1, usable / Math.max(1, sumH));
  let y = PAD + (usable - sumH * fit) / 2;
  if (y < PAD) y = PAD;
  items.forEach((it) => {
    const an = images[it.b.img];
    const L = an.luma;
    const w = an.lumaW;
    const h = an.lumaH;
    const bg = an.bgL || 245;
    const ks = an.scale;
    const dw = Math.max(1, Math.round(it.w * fit));
    const dh = Math.max(1, Math.round(it.h * fit));
    const dx = Math.round((SW - dw) / 2);
    const dy = Math.round(y);
    const drawH = Math.min(dh, SH - dy);
    const sx = Math.max(0, it.b.x0 * ks);
    const sy = Math.max(0, it.b.y0 * ks);
    const sw = Math.max(1, (it.b.x1 - it.b.x0) * ks);
    const sh = Math.max(1, (it.b.y1 - it.b.y0) * ks);
    for (let py = 0; py < drawH; py++) {
      const fy = Math.min(sh - 0.001, Math.max(0, (py + 0.5) / dh * sh - 0.5));
      const y0i = fy | 0;
      const ty = fy - y0i;
      const r0 = Math.min(h - 1, (y0i + sy) | 0);
      const r1 = Math.min(h - 1, r0 + 1);
      let di = ((dy + py) * SW + dx) * 4;
      for (let px = 0; px < dw; px++) {
        const fx = Math.min(sw - 0.001, Math.max(0, (px + 0.5) / dw * sw - 0.5));
        const x0i = fx | 0;
        const tx = fx - x0i;
        const c0 = Math.min(w - 1, (x0i + sx) | 0);
        const c1 = Math.min(w - 1, c0 + 1);
        const l00 = L[r0 * w + c0];
        const l01 = L[r0 * w + c1];
        const l10 = L[r1 * w + c0];
        const l11 = L[r1 * w + c1];
        const lv = (l00 * (1 - tx) + l01 * tx) * (1 - ty) + (l10 * (1 - tx) + l11 * tx) * ty;
        const ink = bg - lv;
        if (ink > 18) {
          const v = Math.min(255, ink * 2.4);
          rgba[di] = 0x40;
          rgba[di + 1] = 0xff;
          rgba[di + 2] = 0x5e;
          rgba[di + 3] = v >= 250 ? 255 : v | 0;
        }
        di += 4;
      }
    }
    y += dh + GAP * fit;
  });
  return rgba;
}

function valleyCuts(data, w, y0, y1, minGap) {
  const n = y1 - y0;
  const cnt = new Float64Array(n);
  for (let y = y0; y < y1; y++) {
    let s = 0;
    const row = y * w * 4;
    for (let x = 24; x < w - 24; x += 2) {
      const i = row + x * 4;
      const L = (data[i] * 299 + data[i + 1] * 587 + data[i + 2] * 114) / 1000;
      if (L < 150) s++;
    }
    cnt[y - y0] = s;
  }
  const sm = new Float64Array(n);
  let peak = 0;
  for (let i = 0; i < n; i++) {
    let s = 0;
    let c = 0;
    for (let k = -8; k <= 8; k++) {
      const j = i + k;
      if (j >= 0 && j < n) { s += cnt[j]; c++; }
    }
    sm[i] = s / c;
    if (sm[i] > peak) peak = sm[i];
  }
  const raw = [0];
  let last = 0;
  for (let i = 8; i < n - 8; i++) {
    if (!(sm[i] <= sm[i - 1] && sm[i] < sm[i + 1])) continue;
    if (sm[i] > peak * 0.22) continue;
    if (i - last < minGap) continue;
    raw.push(i);
    last = i;
  }
  raw.push(n);
  return raw.map((v) => v + y0);
}

function staffsFromMelody(rows, height) {
  if (!rows || rows.length < 2) return null;
  const gaps = [];
  for (let i = 1; i < rows.length; i++) gaps.push(rows[i].y0 - rows[i - 1].y1);
  gaps.sort((a, b) => a - b);
  const med = gaps[(gaps.length / 2) | 0];
  if (med < 80 || med > 520) return null;
  const staffs = [];
  for (let i = 0; i < rows.length; i++) {
    const prevBottom = i > 0 ? rows[i - 1].y1 : 0;
    const nextTop = i + 1 < rows.length ? rows[i + 1].y0 : height;
    const above = rows[i].y0 - prevBottom;
    const below = nextTop - rows[i].y1;
    const y0 = i === 0
      ? Math.max(0, rows[i].y0 - Math.min(260, Math.max(36, above * 0.82)))
      : Math.max(prevBottom + 4, rows[i].y0 - Math.max(12, above * 0.42));
    const y1 = i + 1 < rows.length
      ? nextTop - Math.max(8, below * 0.22)
      : Math.min(height, rows[i].y1 + Math.max(70, below * 0.72));
    if (y1 - y0 < 40) continue;
    staffs.push({ y0, y1 });
  }
  return staffs.length >= 2 ? staffs : null;
}

function expandBlocks(decoded, blocks) {
  const tall = blocks.filter((b) => b.y1 - b.y0 > 80);
  const med = tall.length
    ? tall.map((b) => b.y1 - b.y0).sort((a, b) => a - b)[(tall.length / 2) | 0]
    : 220;
  const gap = Math.max(150, Math.min(260, med * 0.72));
  const out = [];
  blocks.forEach((b) => {
    const h = b.y1 - b.y0;
    if (h < 48) return;
    if (h < gap * 1.7) { out.push(b); return; }
    const cuts = valleyCuts(decoded.rgba, decoded.width, Math.round(b.y0), Math.round(b.y1), gap);
    for (let i = 0; i < cuts.length - 1; i++) {
      const y0 = cuts[i];
      const y1 = cuts[i + 1];
      if (y1 - y0 < 36) continue;
      out.push({ ...b, y0, y1 });
    }
  });
  return out.length ? out : blocks;
}

function rowsOn(rows, block) {
  return rows.filter((row) => {
    if (row.img !== block.img) return false;
    const mid = (row.y0 + row.y1) / 2;
    return mid >= block.y0 && mid < block.y1;
  });
}

function screenEdge(rows, blocks, keyPc) {
  const measures = [];
  blocks.forEach((block) => {
    rowsOn(rows, block).forEach((row) => {
      const ms = row.measures && row.measures.length ? row.measures : [row.notes];
      ms.forEach((m) => measures.push(m));
    });
  });
  return edgeFromMeasures(measures, keyPc);
}

function decodeFile(file) {
  const bytes = fs.readFileSync(file);
  const raw = jpeg.decode(bytes, { useTArray: true, formatAsRGBA: true });
  return { rgba: raw.data, width: raw.width, height: raw.height };
}

const reviewDir = process.env.REVIEW_DIR ? path.resolve(process.env.REVIEW_DIR) : '';
const assetRoot = reviewDir ? path.join(reviewDir, 'assets') : path.join(root, 'aiui-agent', 'assets');
const baked = [];
const onlyId = process.env.SONG_ID || '';

for (const song of (catalog.songs || []).filter((s) => !onlyId || s.id === onlyId)) {
  const images = [];
  const blocks = [];
  const melody = [];
  console.log(song.title);
  for (const rel of song.files || []) {
    const file = path.resolve(root, rel);
    const decoded = decodeFile(file);
    const an = analyzeImage(decoded.rgba, decoded.width, decoded.height, path.basename(file));
    const img = images.length;
    const dark = maskFromRGBA(decoded.rgba, decoded.width, decoded.height);
    const rows = readMelody(dark, decoded.width, decoded.height);
    const fromRows = staffsFromMelody(rows, decoded.height);
    let staffs;
    if (fromRows) {
      const x0 = an.blocks.length ? Math.min.apply(null, an.blocks.map((b) => b.x0)) : 0;
      const x1 = an.blocks.length ? Math.max.apply(null, an.blocks.map((b) => b.x1)) : decoded.width;
      staffs = fromRows.map((s) => ({ x0, x1, y0: s.y0, y1: s.y1 }));
    } else {
      const glued = [];
      an.blocks.forEach((b) => {
        const prev = glued[glued.length - 1];
        const gap = prev ? b.y0 - prev.y1 : 999;
        const span = prev ? Math.max(prev.y1, b.y1) - prev.y0 : 0;
        if (prev && gap < 28 && gap > -6 && span < 320) prev.y1 = Math.max(prev.y1, b.y1);
        else glued.push({ ...b });
      });
      staffs = expandBlocks(decoded, glued).filter((b) => b.y1 - b.y0 >= 48);
    }
    staffs.forEach((b) => blocks.push({ ...b, img }));
    images.push(an);
    rows.forEach((row) => melody.push({ ...row, img }));
    console.log(' ', path.basename(file), decoded.width + 'x' + decoded.height, '行块', an.blocks.length, '切开', staffs.length, '旋律行', rows.length, rows[0] ? rows[0].notes : '');
  }
  const songDir = path.join(assetRoot, song.id);
  fs.mkdirSync(songDir, { recursive: true });
  const layouts = {};
  const synthIndex = {};
  const keyPc = keyPcOf(song.key);
  for (const lines of [2, 3]) {
    const dir = path.join(songDir, 'L' + lines);
    fs.mkdirSync(dir, { recursive: true });
    for (const name of fs.readdirSync(dir)) {
      if (name.endsWith('.jpg')) fs.unlinkSync(path.join(dir, name));
    }
    const screens = [];
    let n = 0;
    for (let i = 0; i < blocks.length; i += lines) {
      const idx = [];
      for (let k = 0; k < lines && i + k < blocks.length; k++) idx.push(i + k);
      n += 1;
      const fileName = String(n).padStart(2, '0') + '.jpg';
      const rgba = renderScreen(images, blocks, idx);
      const encoded = jpeg.encode({ data: rgba, width: SW, height: SH }, 86);
      fs.writeFileSync(path.join(dir, fileName), Buffer.from(encoded.data));
      screens.push('/assets/' + song.id + '/L' + lines + '/' + fileName);
    }
    const notes = [];
    const melodyNotes = [];
    for (let i = 0; i < blocks.length; i += lines) {
      const chunk = [];
      for (let k = 0; k < lines && i + k < blocks.length; k++) chunk.push(blocks[i + k]);
      const edge = screenEdge(melody, chunk, keyPc);
      notes.push(edge.phrase);
      melodyNotes.push(edge.melody);
      const tail = edge.phrase.map((m) => ((m % 12) + 12) % 12).join(',');
      console.log('  ' + lines + '行 第' + notes.length + '屏 小节' + edge.phrase.length + '音 ' + tail);
    }
    const given = givenEdges(song, lines);
    if (given) {
      if (given.length !== notes.length) {
        throw new Error(song.title + ' 每页' + lines + '行：给了 ' + given.length + ' 条边缘音，切出来 ' + notes.length + ' 屏');
      }
      for (let s = 0; s < given.length; s++) {
        notes[s] = notesFromEdge(given[s], song.key || 'D');
        melodyNotes[s] = notes[s].slice();
      }
      console.log('  每页' + lines + '行 用外部边缘音');
    } else {
      for (let s = 0; s < notes.length - 1; s++) {
        const a = notes[s].map((m) => m % 12).join(',');
        const b = notes[s + 1].map((m) => m % 12).join(',');
        if (a && a === b && melodyNotes[s].length > notes[s].length) {
          const mel = melodyNotes[s];
          notes[s] = mel.slice(Math.max(0, mel.length - notes[s].length - 4));
        }
      }
    }
    const synthDir = path.join(root, 'preview', 'out', 'synth', song.id, 'L' + lines);
    fs.mkdirSync(synthDir, { recursive: true });
    notes.forEach((phrase, i) => {
      const pcm = synthPhrase(phrase, { cents: true, chord: true }).pcm;
      const name = String(i + 1).padStart(2, '0') + '.f32';
      fs.writeFileSync(path.join(synthDir, name), Buffer.from(pcm.buffer, pcm.byteOffset, pcm.byteLength));
    });
    layouts[String(lines)] = { screens, notes, melody: melodyNotes };
    synthIndex[String(lines)] = {
      source: given ? 'given' : 'detected',
      screens: notes.map((phrase, i) => ({
        notes: phrase,
        synth: 'L' + lines + '/' + String(i + 1).padStart(2, '0') + '.f32'
      }))
    };
    const empty = notes.filter((row) => row.length < 4).length;
    console.log('  每页' + lines + '行', screens.length + '屏', '小节不足', empty);
  }
  baked.push({
    id: song.id,
    title: song.title,
    key: song.key || 'D',
    layouts
  });
  fs.writeFileSync(
    path.join(root, 'preview', 'out', 'synth', song.id + '.json'),
    JSON.stringify({ id: song.id, title: song.title, key: song.key || 'D', layouts: synthIndex }, null, 2)
  );
}

const outFile = reviewDir
  ? path.join(reviewDir, 'songs.js')
  : path.join(root, 'aiui-agent', 'songs.js');
fs.writeFileSync(outFile, 'export default ' + JSON.stringify(baked) + ';\n');
console.log('wrote', outFile);
