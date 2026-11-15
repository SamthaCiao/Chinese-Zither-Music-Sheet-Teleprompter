<script type="application/json" def>
{
  "navigationBarTitleText": "选曲",
  "disableScroll": true
}
</script>

<script setup>
/* ==========================================================================
 * 古筝演奏琴谱提词器 · 眼镜端
 * 打开先选曲。每页 2 行和 3 行的图在电脑上已经切好，放在 assets 里，由 songs.js 指向。
 * 眼镜只贴当前这一张图，不在眼镜上认行、不做掩膜。前后滑只改高亮，单击镜腿才进入翻谱。
 * 这一屏的图挂上之后才听琴。麦失败时谱留在屏上。跟随在 follow-engine.js。页面里的 log() 必须保留。
 * 录音在按下「开始演奏」后才开。左下角先是校准，校准后才是开始演奏。不接语音。
 * ========================================================================== */

import wx from 'wx';
import DEFAULT_SEQ from '../../seq-config.js';
import { createEar, pushSamples, wantNextScreen, markScreen } from '../../follow-engine.js';
import { pcmToFloat, sampleRateOf, createLevel, levelFrame } from '../../pcm-frame.js';
import { createHeadTurn, anglesFromQuat, takeHead, noteHead, commitHead } from '../../head-turn.js';
import { maskFromRGBA, readMelody, screensFromRows } from '../../jianpu-read.js';
import { takeQuery } from '../../inbox.js';
import SONGS from '../../songs.js';
const SCORE_B64 = '';

function log(msg) {
  try { console.log('[guzheng] ' + msg); } catch (e) {}
}

const FRAME_MS = 40;

function quatOf(q) {
  if (!q) return null;
  if (q.length >= 4) return [q[0], q[1], q[2], q[3]];
  if (q.x != null && q.w != null) return [q.x, q.y, q.z, q.w];
  return null;
}

async function openRecorder(rec) {
  const started = rec.start({
    sampleRate: 16000,
    numberOfChannels: 1,
    format: 'pcm',
    frameSize: FRAME_MS
  });
  if (started && started.then) await started;
}

const FOLLOW = {
  on: false, sr: 0, hop: 256, FRAME: 1024, streamPos: 0, frameIdx: 0,
  flux: [], cflux: [], cframe: [], smoothF: [], thr: 0,
  ring: new Float32Array(1 << 15), ringMask: (1 << 15) - 1, abs: 0,
  pend: [], obs: [], score: [], edges: [0], lead: 0.8,
  alpha: null, path: [], vScreen: 0,
  onCount: 0, blocksSinceUI: 0, lastTurnAt: -1e9, _lagObs: 0
};

/* ---------- radix-2 FFT ---------- */
function fftInplace(re, im) {
  const n = re.length;
  for (let i = 1, j = 0; i < n; i++) {
    let bit = n >> 1;
    for (; j & bit; bit >>= 1) j ^= bit;
    j ^= bit;
    if (i < j) { let t = re[i]; re[i] = re[j]; re[j] = t;
                 t = im[i]; im[i] = im[j]; im[j] = t; }
  }
  for (let len = 2; len <= n; len <<= 1) {
    const ang = -2 * Math.PI / len;
    const wr = Math.cos(ang), wi = Math.sin(ang);
    for (let i = 0; i < n; i += len) {
      let cr = 1, ci = 0;
      for (let k = 0; k < len / 2; k++) {
        const ur = re[i + k], ui = im[i + k];
        const vr = re[i + k + len / 2] * cr - im[i + k + len / 2] * ci;
        const vi = re[i + k + len / 2] * ci + im[i + k + len / 2] * cr;
        re[i + k] = ur + vr; im[i + k] = ui + vi;
        re[i + k + len / 2] = ur - vr; im[i + k + len / 2] = ui - vi;
        const ncr = cr * wr - ci * wi; ci = cr * wi + ci * wr; cr = ncr;
      }
    }
  }
}

const HAN2 = (() => { const a = new Float32Array(1024);
  for (let i = 0; i < 1024; i++) a[i] = .5 - .5 * Math.cos(2 * Math.PI * i / 1023); return a; })();

/** 谱流帧：|X| → log1p(10x) → 与上帧正差分 → 求和 */
function fluxFrame(buf, start, sr) {
  const N = 1024, re = new Float32Array(N), im = new Float32Array(N);
  for (let i = 0; i < N; i++) re[i] = buf[(start + i) & FOLLOW.ringMask] * HAN2[i];
  fftInplace(re, im);
  let s = 0;
  const half = N >> 1;
  if (!FOLLOW._prev) FOLLOW._prev = new Float32Array(half);
  const p = FOLLOW._prev;
  for (let k = 1; k < half; k++) {
    const mag = Math.log1p(10 * Math.hypot(re[k], im[k]));
    const d = mag - p[k];
    if (d > 0) s += d;
    p[k] = mag;
  }
  return s;
}

/** 音高：FFT 自相关 + 短周期优先（抑制倍频） */
function f0ACF(seg, sr) {
  const n = seg.length;
  let m = 0; for (let i = 0; i < n; i++) m += seg[i];
  m /= n;
  let rms = 0;
  const x = new Float32Array(n);
  for (let i = 0; i < n; i++) { x[i] = seg[i] - m; rms += x[i] * x[i]; }
  if (Math.sqrt(rms / n) < 0.008) return 0;
  const N = 1 << Math.ceil(Math.log2(2 * n));
  const re = new Float32Array(N), im = new Float32Array(N);
  for (let i = 0; i < n; i++) re[i] = x[i] * (.5 - .5 * Math.cos(2 * Math.PI * i / (n - 1)));
  fftInplace(re, im);
  for (let k = 0; k < N; k++) { const a = re[k] * re[k] + im[k] * im[k]; re[k] = a; im[k] = 0; }
  fftInplace(re, im);
  const ac = new Float64Array(n);
  for (let i = 0; i < n; i++) ac[i] = re[i] / N;
  if (ac[0] <= 0) return 0;
  for (let i = 0; i < n; i++) ac[i] /= ac[0];
  const tauMin = Math.max(2, Math.floor(sr / 1200)), tauMax = Math.min(Math.floor(sr / 70), n - 2);
  if (tauMax <= tauMin + 2) return 0;
  let bestTau = 0, bestV = 0;
  for (let i = tauMin + 1; i < tauMax; i++) {
    if (ac[i] > ac[i - 1] && ac[i] >= ac[i + 1] && ac[i] > 0.30) {
      if (ac[i] > bestV) { bestV = ac[i]; bestTau = i; }
    }
  }
  if (!bestTau) return 0;
  for (let i = tauMin + 1; i < bestTau; i++) {
    if (ac[i] > ac[i - 1] && ac[i] >= ac[i + 1] && ac[i] >= bestV * 0.88) { bestTau = i; break; }
  }
  let t = bestTau;
  if (1 <= t && t < n - 1) {
    const a = ac[t - 1], b = ac[t], c = ac[t + 1], den = a - 2 * b + c;
    if (Math.abs(den) > 1e-9) t += 0.5 * (a - c) / den;
  }
  return sr / t;
}

const toMidi = function (f) { return f <= 0 ? 0 : Math.round(69 + 12 * Math.log2(f / 440)); };

/* ---------- HMM 在线对齐 ---------- */
function alignInit(score) {
  const SN = score.length;
  FOLLOW.score = score;
  FOLLOW.alpha = new Float64Array(SN).fill(-1e9);
  FOLLOW.alpha[0] = 0;
  FOLLOW.trans = [];
  const stay = Math.log(.55), fwd = Math.log(.92), bwd = Math.log(.06), jump = Math.log(.02);
  for (let i = 0; i < SN; i++) {
    const outs = [[i, stay]];
    if (i + 1 < SN) outs.push([i + 1, fwd]);
    for (let k = 1; k <= 10; k++) if (i - k >= 0) outs.push([i - k, bwd - Math.log(k)]);
    for (let k = 2; k <= 4; k++) if (i + k < SN) outs.push([i + k, jump - Math.log(k)]);
    FOLLOW.trans.push(outs);
  }
  FOLLOW.path = []; FOLLOW.obs = [];
  FOLLOW.vScreen = 0; FOLLOW.lastTurnAt = -1e9;
}

function alignPush(midi, t) {
  const SN = FOLLOW.score.length, a = FOLLOW.alpha, tr = FOLLOW.trans;
  const NEG = -1e9, sigma = 2.2;
  const next = new Float64Array(SN).fill(NEG);
  for (let i = 0; i < SN; i++) {
    const v0 = a[i];
    if (v0 <= NEG / 2) continue;
    const outs = tr[i];
    for (let k = 0; k < outs.length; k++) {
      const v = v0 + outs[k][1];
      if (v > next[outs[k][0]]) next[outs[k][0]] = v;
    }
  }
  for (let j = 0; j < SN; j++) {
    let d = Math.abs(midi - FOLLOW.score[j]) % 12;
    if (d > 6) d = 12 - d;
    d += 3 * Math.floor(Math.abs(midi - FOLLOW.score[j]) / 12);
    next[j] += -0.5 * (d / sigma) * (d / sigma);
  }
  let mx = NEG;
  for (let j = 0; j < SN; j++) if (next[j] > mx) mx = next[j];
  for (let j = 0; j < SN; j++) a[j] = next[j] - mx;
  let arg = 0;
  for (let j = 1; j < SN; j++) if (a[j] > a[arg]) arg = j;
  FOLLOW.path.push(arg);
  FOLLOW.obs.push({ midi: midi, t: t });
  return arg;
}

/* ---------- 序列解析（跟随用）：midi 数字 或 简谱（| 分屏） ---------- */
const DEG = { 1: 0, 2: 2, 3: 4, 4: 5, 5: 7, 6: 9, 7: 11 };
function parseSeq(txt, keyPc) {
  const segs = txt.split('|');
  const edges = [0];
  const score = [];
  for (let si = 0; si < segs.length; si++) {
    const seg = segs[si].trim();
    if (!seg) continue;
    const toks = seg.split(/[\s,]+/);
    for (let ti = 0; ti < toks.length; ti++) {
      const tok = toks[ti];
      if (!tok) continue;
      let v = null;
      if (/^[1-7][+\-]*$/.test(tok)) {
        let oct = 0;
        for (let ci = 1; ci < tok.length; ci++) oct += tok[ci] === '+' ? 1 : -1;
        v = 60 + keyPc + DEG[+tok[0]] + 12 * oct;
      } else if (/^\d{2,3}$/.test(tok)) {
        v = parseInt(tok, 10);
      }
      if (v != null && v >= 30 && v <= 100) score.push(v);
    }
    edges.push(score.length);
  }
  if (!score.length) return null;
  return { score: score, edges: edges };
}

/* ==========================================================================
 * 谱图管线（与原型逐行同源，纯计算无 DOM 依赖）
 * ========================================================================== */
const SW = 480, SH = 352, HINT_H = 22;
const PAD = 10, GAP = 7;
const MAX_W = 900, MAX_H = 4000;   // 与网页预览同一档，眼镜上先出画面
const INK_Q = 48, INK_SPAN = 512, INK_MAX = 2;

const ST = {
  bitmap: null,           // 谱图位图（ImageBitmap）
  imgW: 0, imgH: 0,
  scale: 1,
  blocks: [], screens: [], idx: 0,
  sens: 70, merge: 0.35,
  inkA: null, inkW: 0, inkH: 0, inkReady: false,
  bgL: 255, inks: [],
  pages: [], pageCount: 1, wmRemoved: false, deepCut: 0,
  melodyRows: [],
  linesPerScreen: 3,
  keyPc: 2,
  pickAt: 0,
  analyzedId: '',
  turnDelay: 0,
  phase: 'pick',
  preset: null,
  bitmaps: null,
  plates: null,
  picMiss: false,
  songTitle: '',
  hint: '选曲',
  listening: false,
  splitNote: '',
  busyWait: false,
  waitDots: '·',
  micText: '',
  running: false,
  status: '说「拍琴谱」\n对准琴谱\n看谱不会自动拍\n拍完才能翻页'
};

let _clip = null;
let _utt = null;
function playClip(name) {
  const src = '/assets/' + name + '.wav';
  try {
    if (typeof Sound !== 'function') return false;
    if (_clip && _clip.stop) { try { _clip.stop(); } catch (e) {} }
    _clip = new Sound(src);
    _clip.volume = 1;
    _clip.play();
    log('播放 ' + name);
    return true;
  } catch (e) {
    log('语音文件没播出来 ' + (e && e.message ? e.message : e));
    return false;
  }
}

function say(text) {
  log('说: ' + text);
  let name = '';
  if (text.indexOf('没看到') >= 0) name = 'fail';
  else if (text.indexOf('还没有谱') >= 0) name = 'noscore';
  else if (text.indexOf('看着琴谱') >= 0) name = 'hello';
  else if (text.indexOf('拍到了') >= 0 || text.indexOf('收下了') >= 0) name = 'shot';
  else if (text.indexOf('开始听') >= 0) name = 'listen';
  if (name && playClip(name)) return;
  try {
    const synth = (typeof speechSynthesis !== 'undefined') ? speechSynthesis : null;
    const Utter = (typeof SpeechSynthesisUtterance === 'function') ? SpeechSynthesisUtterance : null;
    if (!synth || !Utter) {
      log('这台设备没有语音合成');
      return;
    }
    _utt = new Utter(text);
    _utt.lang = 'zh-CN';
    _utt.volume = 1;
    synth.speak(_utt);
  } catch (e) {
    log('播报失败 ' + (e && e.message ? e.message : e));
  }
}

function hasScore() {
  return !!(ST.preset && ST.preset.length);
}

function hasMelody() {
  if (ST.followScreens && ST.followScreens.length) return true;
  return !!(ST.melodyRows && ST.melodyRows.length);
}

function pageKept(snap) {
  const pages = ST.pages || [];
  const last = pages[pages.length - 1];
  return pages.length > ((snap && snap.pages) ? snap.pages.length : 0)
    && !!(last && last.cropOk)
    && (ST.blocks || []).length > ((snap && snap.blocks) ? snap.blocks.length : 0);
}

function photoOptions() {
  return { quality: 'high', mode: 'telephoto', enableSystemPreview: false };
}

async function bitmapFromEncoded(photo) {
  if (photo && photo.width && photo.height) return photo;
  let blob = photo;
  if (photo && photo.data) {
    const buf = photo.data;
    const bytes = (typeof ArrayBuffer !== 'undefined' && buf instanceof ArrayBuffer) ? new Uint8Array(buf)
      : (typeof ArrayBuffer !== 'undefined' && ArrayBuffer.isView(buf) ? new Uint8Array(buf.buffer, buf.byteOffset, buf.byteLength) : null);
    if (!bytes) throw new Error('照片没有像素');
    blob = new Blob([bytes], { type: photo.mimeType || 'image/jpeg' });
  }
  if (!blob || typeof createImageBitmap !== 'function') throw new Error('解不开照片');
  const bitmap = await createImageBitmap(blob);
  if (!bitmap || !bitmap.width) throw new Error('没有取到画面');
  return bitmap;
}

function trySaveAlbum(photo) {
  try {
    if (!photo || !photo.data || !wx || !wx.getFileSystemManager || !wx.saveImageToPhotosAlbum) return;
    const base = (wx.env && wx.env.USER_DATA_PATH) ? wx.env.USER_DATA_PATH : '';
    if (!base) return;
    const path = base + '/score-shot.jpg';
    wx.getFileSystemManager().writeFile({
      filePath: path,
      data: photo.data,
      success: function () {
        try { wx.saveImageToPhotosAlbum({ filePath: path }); } catch (e) {}
      }
    });
  } catch (e) {}
}

function openBlankToShoot() {
  try {
    if (typeof window !== 'undefined' && window.open) {
      window.open('/pages/index/index?shoot=1', '_blank');
      return true;
    }
  } catch (e) {}
  return false;
}

async function grabScoreFrame() {
  let ctx = null;
  try {
    ctx = (wx && wx.media && wx.media.createCameraContext) ? wx.media.createCameraContext() : null;
  } catch (e) { ctx = null; }
  if (ctx && ctx.takePhoto) {
    const photo = await ctx.takePhoto(photoOptions());
    trySaveAlbum(photo);
    return bitmapFromEncoded(photo);
  }
  const devices = navigator.mediaDevices;
  if (!devices || !devices.getUserMedia) throw new Error('页面里没有相机');
  const stream = await devices.getUserMedia({ video: true });
  let track = null;
  try {
    track = stream.getVideoTracks()[0];
    if (!track) throw new Error('没有相机画面');
    if (typeof ImageCapture !== 'function') throw new Error('页面里不能取帧');
    const cap = new ImageCapture(track);
    if (!cap.takePhoto) {
      const frame = await cap.grabFrame();
      if (!frame || !frame.width) throw new Error('没有取到画面');
      return frame;
    }
    const blob = await cap.takePhoto(photoOptions());
    trySaveAlbum(blob);
    return bitmapFromEncoded(blob);
  } finally {
    if (track) try { track.stop(); } catch (e) {}
    const tracks = stream.getTracks();
    for (let i = 0; i < tracks.length; i++) try { tracks[i].stop(); } catch (e) {}
  }
}

/* ---------- 墨色探测 ---------- */
function probeInk(px, w, h) {
  const lh = new Uint32Array(256);
  for (let i = 0; i < px.length; i += 4) {
    lh[(px[i] * 299 + px[i + 1] * 587 + px[i + 2] * 114) / 1000 | 0]++;
  }
  let bgL = 255, top = 0;
  for (let l = 0; l < 256; l++) if (lh[l] > top) { top = lh[l]; bgL = l; }
  const cut = bgL - Math.max(14, bgL * 0.12);
  const den = Math.max(1, bgL * 0.65);
  const hist = new Float32Array(INK_Q * INK_Q);
  for (let i = 0; i < px.length; i += 4) {
    const r = px[i], g = px[i + 1], b = px[i + 2];
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
    let bi = -1, bv = 0;
    for (let i = 0; i < work.length; i++) if (work[i] > bv) { bv = work[i]; bi = i; }
    if (bi < 0 || bv <= 0) break;
    const cx = bi % INK_Q, cy = (bi / INK_Q) | 0;
    peaks.push({ u: (cx + 0.5) * INK_SPAN / INK_Q - 256, v: (cy + 0.5) * INK_SPAN / INK_Q - 256 });
    for (let dy = -2; dy <= 2; dy++) for (let dx = -2; dx <= 2; dx++) {
      const nx = cx + dx, ny = cy + dy;
      if (nx >= 0 && ny >= 0 && nx < INK_Q && ny < INK_Q) work[ny * INK_Q + nx] = 0;
    }
  }
  if (!peaks.length) return { bgL, inks: [{ u: 0, v: 0, Lk: 60, frac: 1 }] };
  const acc = peaks.map(() => ({ n: 0, su: 0, sv: 0, ls: [] }));
  for (let i = 0; i < px.length; i += 4) {
    const r = px[i], g = px[i + 1], b = px[i + 2];
    const L = (r * 299 + g * 587 + b * 114) / 1000;
    if (L >= cut) continue;
    const u = r - g, v = g - b;
    let bi = 0, bd = 1e9;
    for (let k = 0; k < peaks.length; k++) {
      const d = (u - peaks[k].u) ** 2 + (v - peaks[k].v) ** 2;
      if (d < bd) { bd = d; bi = k; }
    }
    if (bd > 40 * 40) continue;
    const a = acc[bi];
    a.n++; a.su += u; a.sv += v;
    if (a.ls.length < 4000) a.ls.push(L);
  }
  const inks = [];
  let totalN = 0;
  acc.forEach(a => totalN += a.n);
  acc.forEach(a => {
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
  for (let k = 1; k < inks.length && out.length < INK_MAX; k++) {
    const d = Math.hypot(inks[k].u - out[0].u, inks[k].v - out[0].v);
    if (d < 26) continue;
    if (inks[k].frac < inks[0].frac * 0.10) continue;
    if (inks[k].Lk > inks[0].Lk + gap * 0.35) continue;
    out.push(inks[k]);
  }
  return { bgL, inks: out };
}

async function buildInkMask(px, w, h, bgL, inks) {
  const A = new Uint8Array(w * h);
  const use = inks.map(k => {
    const kr = (2 * k.u + k.v) / 3, kg = (-k.u + k.v) / 3, kb = (-k.u - 2 * k.v) / 3;
    return { kr, kg, kb, mag2: kr * kr + kg * kg + kb * kb, Lk: k.Lk };
  });
  const DC = 30 * 30;
  const RANGE = Math.max(12, bgL * 0.9);
  const deepCut = use[0].Lk + (bgL - use[0].Lk) * 0.26;
  ST.deepCut = deepCut;
  for (let i = 0, p = 0; i < px.length; i += 4, p++) {
    if (p > 0 && (p % (w * 40)) === 0) { bumpDots(); await later(16); }
    const r = px[i], g = px[i + 1], b = px[i + 2];
    const L = (r * 299 + g * 587 + b * 114) / 1000;
    if (L >= bgL - 3) { A[p] = 0; continue; }
    const cr = r - L, cg = g - L, cb = b - L;
    let match = 0;
    for (let k = 0; k < use.length; k++) {
      const m = use[k];
      let res2;
      if (m.mag2 < 100) {
        res2 = cr * cr + cg * cg + cb * cb;
      } else {
        const t = (cr * m.kr + cg * m.kg + cb * m.kb) / m.mag2;
        if (t < 0.05) continue;
        const er = cr - t * m.kr, eg = cg - t * m.kg, eb = cb - t * m.kb;
        res2 = er * er + eg * eg + eb * eb;
      }
      const mm = 1 - res2 / DC;
      if (mm > match) match = mm;
      if (match >= 1) break;
    }
    // 彩色水印即使局部偏暗，也不因“够黑”被收成音符。
    if (match <= 0) { A[p] = 0; continue; }
    let depth = (bgL - L) / RANGE;
    if (depth > 1) depth = 1;
    if (depth <= 0) { A[p] = 0; continue; }
    if (match <= 0.35) { A[p] = 0; continue; }
    A[p] = Math.min(1, depth * match) ** 1.15 * 255 | 0;
  }
  let n2 = 0;
  const bh = new Uint32Array(256);
  for (let p = 0; p < A.length; p++) if (A[p] > 26) { bh[A[p]]++; n2++; }
  let mode = 255;
  if (n2 > 500) {
    let acc = 0;
    for (let i = 255; i >= 0; i--) { acc += bh[i]; if (acc >= n2 * 0.15) { mode = i; break; } }
  }
  return { A, mode };
}

function morph(src, w, h, r, isErode) {
  const tmp = new Uint8Array(w * h), out = new Uint8Array(w * h);
  for (let y = 0; y < h; y++) {
    const b = y * w;
    for (let x = r; x < w - r; x++) {
      let ok = 1;
      for (let d = -r; d <= r; d++) {
        const v = src[b + x + d];
        if (isErode ? !v : v) { ok = 0; break; }
      }
      tmp[b + x] = ok;
    }
  }
  for (let y = r; y < h - r; y++) {
    for (let x = 0; x < w; x++) {
      let ok = 1;
      for (let d = -r; d <= r; d++) {
        const v = tmp[(y + d) * w + x];
        if (isErode ? !v : v) { ok = 0; break; }
      }
      out[y * w + x] = ok;
    }
  }
  return out;
}

function suppressWatermark(dark, w, h, darkTotal) {
  const er = morph(dark, w, h, 2, true);
  const lab = new Int32Array(w * h);
  const stack = new Int32Array(w * h);
  const sizes = [0]; let nextId = 1;
  for (let i = 0; i < er.length; i++) {
    if (!er[i] || lab[i]) continue;
    let sp = 0; stack[sp++] = i; lab[i] = nextId; let size = 0;
    while (sp > 0) {
      const p = stack[--sp]; size++;
      const cx = p % w, cy = (p / w) | 0;
      for (let dy = -1; dy <= 1; dy++) for (let dx = -1; dx <= 1; dx++) {
        if (!dx && !dy) continue;
        const nx = cx + dx, ny = cy + dy;
        if (nx < 0 || ny < 0 || nx >= w || ny >= h) continue;
        const q = ny * w + nx;
        if (er[q] && !lab[q]) { lab[q] = nextId; stack[sp++] = q; }
      }
    }
    sizes[nextId++] = size;
  }
  const bigIds = [];
  for (let id = 1; id < nextId; id++) if (sizes[id] >= 120) bigIds.push(id);
  if (bigIds.length < 2) return null;
  const ratio = sizes.reduce((s, v, i) => i ? s + v : 0, 0) / Math.max(1, darkTotal);
  if (ratio >= 0.25) return null;
  const core = new Uint8Array(w * h);
  for (let i = 0; i < lab.length; i++) if (lab[i] && bigIds.indexOf(lab[i]) > -1) core[i] = 1;
  const wm = morph(core, w, h, 5, false);
  for (let i = 0; i < dark.length; i++) if (wm[i]) dark[i] = 0;
  return wm;
}

function detectVSeams(dark, w, h) {
  const colCnt = new Uint32Array(w);
  for (let y = 0; y < h; y++) {
    const b = y * w;
    for (let x = 0; x < w; x++) if (dark[b + x]) colCnt[x]++;
  }
  const floor = Math.max(2, h * 0.001);
  const minSw = Math.max(12, w * 0.03);
  const seams = [];
  let inS = false, st = 0;
  for (let x = 0; x <= w; x++) {
    const v = x < w ? colCnt[x] <= floor : false;
    if (v) { if (!inS) { inS = true; st = x; } }
    else if (inS) { inS = false; if (x - st >= minSw) seams.push([st, x]); }
  }
  const pages = [];
  let prev = 0;
  for (const [a, b] of seams) {
    if (a - prev >= w * 0.20) pages.push([prev, a]);
    prev = b;
  }
  if (w - prev >= w * 0.20) pages.push([prev, w]);
  return pages.length > 1 ? pages : [[0, w]];
}

function splitRows(dark, w, h, x0, x1, sens, merge) {
  const pw = x1 - x0;
  const cnt = new Uint32Array(h);
  for (let y = 0; y < h; y++) {
    let c = 0; const b = y * w;
    for (let x = x0; x < x1; x++) if (dark[b + x]) c++;
    cnt[y] = c;
  }
  const noiseFloor = Math.max(2, pw * 0.001) * (sens / 70);
  let isC = new Uint8Array(h);
  for (let y = 0; y < h; y++) isC[y] = (cnt[y] > noiseFloor && cnt[y] <= pw * 0.70) ? 1 : 0;
  const filled = new Uint8Array(h);
  for (let y = 0; y < h; y++) {
    if (isC[y]) { filled[y] = 1; continue; }
    let up = -1, dn = -1;
    for (let k = 1; k <= 2 && up < 0; k++) if (y - k >= 0 && isC[y - k]) up = k;
    for (let k = 1; k <= 2 && dn < 0; k++) if (y + k < h && isC[y + k]) dn = k;
    if (up > 0 && dn > 0) filled[y] = 1;
  }
  isC = filled;
  const raw = [];
  let inB = false, st = 0;
  for (let y = 0; y <= h; y++) {
    const v = y < h ? isC[y] : 0;
    if (v) { if (!inB) { inB = true; st = y; } }
    else if (inB) { inB = false; raw.push([st, y]); }
  }
  const minH = Math.max(4, h * 0.004);
  const bl = raw.filter(([a, b]) => b - a >= minH);
  const avgH = bl.length ? bl.reduce((s, b) => s + (b[1] - b[0]), 0) / bl.length : 0;
  const mg = avgH * merge * 0.9;
  const merged = [];
  for (const b of bl) {
    if (merged.length && b[0] - merged[merged.length - 1][1] < mg) merged[merged.length - 1][1] = b[1];
    else merged.push([b[0], b[1]]);
  }
  return merged;
}

/** 画面里的谱纸：暗笔画像素旁边是亮、颜色淡的纸。桌面和墙通常更暗或更艳，不收进主体。 */
function cropToScore(px, w, h) {
  const step = Math.max(2, (Math.max(w, h) / 240) | 0);
  const xs = new Uint16Array(w);
  const ys = new Uint16Array(h);
  let n = 0;
  for (let y = 0; y < h; y += step) {
    const row = y * w;
    for (let x = 0; x < w; x += step) {
      const i = (row + x) * 4;
      const r = px[i], g = px[i + 1], b = px[i + 2];
      const L = (r * 299 + g * 587 + b * 114) / 1000;
      const sat = Math.max(r, g, b) - Math.min(r, g, b);
      if (L >= 115 || sat > 42) continue;
      let paper = 0;
      const dirs = [step * 4, 0, -step * 4, 0, 0, step * 4, 0, -step * 4];
      for (let k = 0; k < 8; k += 2) {
        const nx = x + dirs[k], ny = y + dirs[k + 1];
        if (nx < 0 || ny < 0 || nx >= w || ny >= h) continue;
        const j = (ny * w + nx) * 4;
        const rr = px[j], gg = px[j + 1], bb = px[j + 2];
        const LL = (rr * 299 + gg * 587 + bb * 114) / 1000;
        const sat = Math.max(rr, gg, bb) - Math.min(rr, gg, bb);
        if (LL >= 150 && sat <= 72) paper++;
      }
      if (paper < 1) continue;
      xs[x]++;
      ys[y]++;
      n++;
    }
  }
  if (n < 40) return null;
  function edge(hist, len, fromStart) {
    let acc = 0;
    const limit = n * 0.02;
    if (fromStart) {
      for (let i = 0; i < len; i++) {
        acc += hist[i];
        if (acc > limit) return i;
      }
      return 0;
    }
    for (let i = len - 1; i >= 0; i--) {
      acc += hist[i];
      if (acc > limit) return i;
    }
    return len - 1;
  }
  let x0 = edge(xs, w, true);
  let x1 = edge(xs, w, false);
  let y0 = edge(ys, h, true);
  let y1 = edge(ys, h, false);
  const padX = Math.max(8, (x1 - x0) * 0.05);
  const padY = Math.max(8, (y1 - y0) * 0.05);
  x0 = Math.max(0, x0 - padX) | 0;
  y0 = Math.max(0, y0 - padY) | 0;
  x1 = Math.min(w - 1, x1 + padX) | 0;
  y1 = Math.min(h - 1, y1 + padY) | 0;
  const cw = x1 - x0 + 1, ch = y1 - y0 + 1;
  if (cw < w * 0.22 || ch < h * 0.18) return null;
  if (cw * ch > w * h * 0.9) return null;
  const out = new Uint8ClampedArray(cw * ch * 4);
  for (let y = 0; y < ch; y++) {
    const src = ((y0 + y) * w + x0) * 4;
    out.set(px.subarray(src, src + cw * 4), y * cw * 4);
  }
  return { px: out, w: cw, h: ch };
}

function later(ms) {
  return new Promise(function (r) { setTimeout(r, ms || 0); });
}

function bumpDots() {
  if (!ST.busyWait || !PAGE || !PAGE.setData) return;
  const now = Date.now();
  if (now - (ST._dotAt || 0) < 280) return;
  ST._dotAt = now;
  const frames = ['·', '··', '···'];
  ST._dotI = ((ST._dotI || 0) + 1) % frames.length;
  ST.waitDots = frames[ST._dotI];
  try { PAGE.setData({ showWait: true, waitDots: ST.waitDots }); } catch (e) {}
}

async function downscaleRGBA(rgba, w, h) {
  const scale = Math.min(1, MAX_W / w, MAX_H / h);
  if (scale === 1) return { rgba: rgba, w: w, h: h, scale: 1 };
  const nw = Math.max(1, Math.round(w * scale));
  const nh = Math.max(1, Math.round(h * scale));
  const out = new Uint8ClampedArray(nw * nh * 4);
  for (let y = 0; y < nh; y++) {
    if ((y & 31) === 0) { bumpDots(); await later(16); }
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
  return { rgba: out, w: nw, h: nh, scale: scale };
}

function rgbaOfBitmap(bmp) {
  const w = bmp.width, h = bmp.height;
  const read = function (g) {
    if (!g || !g.getImageData) return null;
    try { if (g.flush) g.flush(); } catch (e) {}
    let img = null;
    try { img = g.getImageData(0, 0, w, h); } catch (e) { img = null; }
    if (img && img.data && img.data.length >= w * h * 4) return img.data;
    return null;
  };
  try {
    if (typeof OffscreenCanvas === 'function') {
      const c = new OffscreenCanvas(w, h);
      const g = c.getContext('2d');
      g.drawImage(bmp, 0, 0);
      const data = read(g);
      if (data) return data;
    }
  } catch (e) { log('OffscreenCanvas ' + (e && e.message ? e.message : e)); }
  try {
    if (typeof Canvas === 'function') {
      const c = new Canvas(w, h);
      const g = c.getContext('2d');
      g.drawImage(bmp, 0, 0);
      const data = read(g);
      if (data) return data;
    }
  } catch (e) { log('Canvas ' + (e && e.message ? e.message : e)); }
  return null;
}

/** 谱图分析。像素按原图尺寸读出再缩小，和 preview/pipeline.js 同一条，不用那块被样式缩过的 workcv。 */
async function analyzeBitmap(opts) {
  if (!ST.bitmap) return;
  const append = !!(opts && opts.append);
  const prevBlocks = append && ST.blocks ? ST.blocks.slice() : [];
  const prevRows = append && ST.melodyRows ? ST.melodyRows.slice() : [];
  const prevPages = append && ST.pages ? ST.pages.slice() : [];
  const t0 = Date.now();
  const full = rgbaOfBitmap(ST.bitmap);
  if (!full) throw new Error('原图像素没读到');
  const src = await downscaleRGBA(full, ST.imgW, ST.imgH);
  const px = src.rgba;
  const w = src.w;
  const h = src.h;
  const scale = src.scale;
  ST.scale = scale;
  log('原图缩小 ' + ST.imgW + 'x' + ST.imgH + ' → ' + w + 'x' + h);

  const prof = probeInk(px, w, h);
  ST.bgL = prof.bgL; ST.inks = prof.inks;
  const built = await buildInkMask(px, w, h, prof.bgL, prof.inks);
  const cutIn = Math.max(2, built.mode * 0.12);
  const A = new Uint8Array(built.A.length);
  for (let i = 0; i < built.A.length; i++) {
    const v = built.A[i];
    A[i] = v <= cutIn ? 0 : Math.min(255, (v - cutIn) / Math.max(1, built.mode - cutIn) * built.mode) | 0;
  }
  ST.inkA = A;
  ST.inkW = w; ST.inkH = h;

  const dark = new Uint8Array(w * h);
  for (let i = 0; i < A.length; i++) if (A[i] > 18) dark[i] = 1;
  ST.wmRemoved = false;

  const pages = (w > h * 1.08) ? detectVSeams(dark, w, h) : [[0, w]];
  ST.pageCount = pages.length;

  ST.blocks = [];
  pages.forEach((pg, pi) => {
    const rows = splitRows(dark, w, h, pg[0], pg[1], ST.sens, ST.merge);
    if (!rows.length) return;
    const gaps = [];
    for (let i = 1; i < rows.length; i++) gaps.push(rows[i][0] - rows[i - 1][1]);
    gaps.sort((a, b) => a - b);
    const med = gaps.length ? gaps[(gaps.length / 2) | 0] : 0;
    const thr = Math.max(3 / scale, med * 0.55);
    const sets = [[rows[0]]];
    for (let i = 1; i < rows.length; i++) {
      if (rows[i][0] - rows[i - 1][1] < thr) sets[sets.length - 1].push(rows[i]);
      else sets.push([rows[i]]);
    }
    let pageMin = pg[1], pageMax = pg[0] - 1;
    for (let y = 0; y < h; y++) {
      const base = y * w;
      for (let x = pg[0]; x < pg[1]; x++) {
        if (dark[base + x]) { if (x < pageMin) pageMin = x; if (x > pageMax) pageMax = x; }
      }
    }
    if (pageMin > pageMax) { pageMin = pg[0]; pageMax = pg[1] - 1; }
    let prevY1 = 0;
    sets.forEach((set, si) => {
      const a0 = set[0][0], b0 = set[set.length - 1][1];
      const gh = b0 - a0;
      const pad = Math.min(gh * 0.14, 44 / scale);
      const nextA = si < sets.length - 1 ? sets[si + 1][0][0] : h;
      const y0 = Math.max(prevY1 + (a0 - prevY1) * 0.35, a0 - pad);
      const y1 = Math.min(nextA - (nextA - b0) * 0.35, b0 + pad);
      prevY1 = b0;
      ST.blocks.push({
        pi,
        x0: Math.max(pg[0] / scale, (pageMin - 3) / scale),
        x1: Math.min(pg[1] / scale, (pageMax + 4) / scale),
        y0: Math.max(0, y0 / scale),
        y1: Math.min(ST.imgH, y1 / scale)
      });
    });
  });
  ST.blocks.sort((a, b) => a.pi - b.pi || a.y0 - b.y0);

  const pageRec = { A: ST.inkA, w: ST.inkW, h: ST.inkH, scale: ST.scale, bgL: prof.bgL };
  const stored = prevPages.concat([pageRec]);
  const pi = stored.length - 1;
  const blocks = ST.blocks.map(function (b) { b.pi = pi; return b; });
  let rows = [];
  if (!(opts && opts.skipMelody)) {
    try {
      const melody = readMelody(maskFromRGBA(px, w, h), w, h);
      if (melody.length) rows = melody.map(function (r) { return r.notes; });
    } catch (e) {
      log('认谱失败: ' + (e && e.message ? e.message : e));
    }
  }
  ST.pages = stored;
  ST.blocks = prevBlocks.concat(blocks);
  ST.melodyRows = prevRows.concat(rows);
  if (opts && opts.holdScreens) {
    log('一页已分析 · 行 ' + rows.length);
    return;
  }

  buildScreens();
  ST.idx = 0;
  ST.inkReady = true;
  ST.status = '';
  log('谱图就绪：' + ST.blocks.length + ' 组 / ' + ST.pageCount + ' 页 / ' +
      ST.screens.length + ' 屏 · ' + (Date.now() - t0) + 'ms' +
      (ST.wmRemoved ? ' · 已抑制水印' : ''));
}

/** 以最宽谱行为基准统一缩放 */
function baseScale() {
  let maxW = 1;
  ST.blocks.forEach(b => { maxW = Math.max(maxW, b.x1 - b.x0); });
  return (SW - PAD * 2) / maxW;
}
function shownH(b, s0) { return (b.y1 - b.y0) * s0; }

function keyPcOf(name) {
  const map = { C: 0, D: 2, E: 4, F: 5, G: 7, A: 9, B: 11 };
  const k = String(name || 'D').trim().toUpperCase();
  return map[k] == null ? 2 : map[k];
}

function currentSong() {
  const list = SONGS || [];
  return list[ST.pickAt] || list[0] || null;
}

function buildScreens() {
  const n = ST.linesPerScreen === 2 ? 2 : 3;
  const s0 = baseScale();
  const usable = SH - HINT_H - 22;
  const out = [];
  let group = [];
  let acc = 0;
  for (let i = 0; i < ST.blocks.length; i++) {
    const hh = shownH(ST.blocks[i], s0);
    const full = group.length > 0 && (group.length >= n || acc + GAP + hh > usable);
    if (full) {
      out.push(group);
      group = [];
      acc = 0;
    }
    group.push(i);
    acc += hh + (group.length > 1 ? GAP : 0);
  }
  if (group.length) out.push(group);
  ST.screens = out;
  ST.followScreens = screensFromRows(ST.melodyRows || [], n, ST.keyPc == null ? 2 : ST.keyPc);
}

/** 眼镜屏完整重绘。
 *  实现：fillRect 黑底 + fillText 角标 → getImageData 取整屏像素（黑底与
 *  文字已在其中）→ 谱块双线性采样直接写进同一块像素 → putImageData 贴回。
 *  只依赖 getImageData / putImageData 往返，不依赖 ImageData 构造器。 */
let PAGE = null;

function showImportStatus() {
  const n = (ST.pages && ST.pages.length) || 0;
  ST.phase = 'import';
  ST.hint = n ? ('已收 ' + n + ' 张\n单击镜腿再拍') : '单击镜腿拍谱';
}

function frameIsBlurry(bitmap) {
  if (!bitmap || !bitmap.width) return false;
  let cx = null;
  try { cx = wx.createCanvasContext('workcv'); } catch (e) { return false; }
  if (!cx || !cx.getImageData) return false;
  const dw = 160;
  const dh = Math.max(1, Math.round(bitmap.height * dw / bitmap.width));
  try {
    cx.drawImage(bitmap, 0, 0, dw, dh);
    cx.flush();
  } catch (e) { return false; }
  let data = null;
  try { data = cx.getImageData(0, 0, dw, dh).data; } catch (e) { return false; }
  if (!data) return false;
  let acc = 0;
  let n = 0;
  for (let y = 0; y < dh; y += 2) {
    const row = y * dw * 4;
    for (let x = 0; x < dw - 1; x += 2) {
      const i = row + x * 4;
      const g0 = data[i] * 0.299 + data[i + 1] * 0.587 + data[i + 2] * 0.114;
      const g1 = data[i + 4] * 0.299 + data[i + 5] * 0.587 + data[i + 6] * 0.114;
      acc += Math.abs(g0 - g1);
      n++;
    }
  }
  if (!n) return false;
  return acc / n < 6;
}

function publishHint() {
  const lines = String(ST.hint || '导入谱子').split('\n');
  const show = ST.phase !== 'show';
  if (!PAGE || !PAGE.setData) return;
  PAGE.setData({
    showHint: show,
    line1: show ? (lines[0] || '') : '',
    line2: show ? (lines[1] || '') : '',
    line3: show ? (lines.slice(2).join('') || '') : ''
  });
}

function scoreContext() {
  if (ST._scoreCx) return ST._scoreCx;
  try { ST._scoreCx = wx.createCanvasContext('score'); } catch (e) { ST._scoreCx = null; }
  return ST._scoreCx;
}

function paintStage() {
  const cx = scoreContext();
  if (!cx) return;
  cx.fillStyle = '#000000';
  cx.fillRect(0, 0, SW, SH);
  try { cx.flush(); } catch (e) {}
}

function inkSum(image) {
  if (!image || !image.data) return 0;
  const d = image.data;
  let s = 0;
  for (let i = 0; i < d.length; i += 997) s = (s + d[i] + d[i + 1] + d[i + 2]) & 65535;
  return s;
}

function bakePlate(bmp) {
  const dh = SH - HINT_H;
  try {
    if (typeof Canvas !== 'function' || !bmp) return null;
    const canvas = new Canvas(SW, dh);
    const oc = canvas.getContext('2d');
    if (!oc) return null;
    oc.fillStyle = '#000000';
    oc.fillRect(0, 0, SW, dh);
    oc.drawImage(bmp, 0, 0, SW, dh);
    try { if (oc.flush) oc.flush(); } catch (e) {}
    let image = null;
    try { image = oc.getImageData(0, 0, SW, dh); } catch (e) { image = null; }
    if (image && image.data && typeof ImageData === 'function') {
      try {
        const copy = new Uint8ClampedArray(image.data);
        image = new ImageData(copy, SW, dh);
      } catch (e) {}
    }
    return { canvas: canvas, image: image };
  } catch (e) {
    return null;
  }
}

function paintPixels() {
  const cx = scoreContext();
  if (!cx) return;
  cx.fillStyle = '#000000';
  cx.fillRect(0, 0, SW, SH);
  const plate = ST.plates && ST.plates[ST.idx];
  let drew = false;
  if (plate && plate.image) {
    try { cx.putImageData(plate.image, 0, 0); drew = true; } catch (e) { drew = false; }
  }
  if (!drew && plate && plate.canvas) {
    try { cx.drawImage(plate.canvas, 0, 0); drew = true; } catch (e) {}
  }
  if (!drew) {
    const bmp = ST.bitmaps && ST.bitmaps[ST.idx];
    if (bmp) {
      try { blitBitmap(cx, bmp, SH - HINT_H); } catch (e) { log('铺屏失败 ' + (e && e.message ? e.message : e)); }
    }
  }
  try { cx.flush(); } catch (e) {}
}

function paintPreset() {
  const src = (ST.preset && ST.preset[ST.idx]) || '';
  try { console.log('[guzheng] paint ' + (ST.idx + 1) + ' ' + src); } catch (e) {}
  if (ST.picMiss) paintPixels();
  else paintStage();
}

function headTip() {
  const head = PAGE && PAGE._head;
  if (head && head.live) return '前滑或平视下页 · 后滑或低头上页';
  return '前滑下页 · 后滑上页 · 双击返回';
}

function renderScreen() {
  if (ST.phase === 'pick' || ST.phase === 'split') {
    if (PAGE && PAGE.setData) {
      const split = ST.phase === 'split';
      const songs = SONGS || [];
      const title = (currentSong() || {}).title || '';
      const lines = ST.linesPerScreen === 2 ? 2 : 3;
      const at = Math.max(0, Math.min(Math.max(0, songs.length - 1), ST.pickAt || 0));
      const vis = [];
      const showN = Math.min(4, songs.length);
      let start = 0;
      if (songs.length > showN) start = Math.max(0, Math.min(at - 1, songs.length - showN));
      for (let s = 0; s < 4; s++) {
        const idx = start + s;
        if (s < showN && songs[idx]) vis.push({ title: songs[idx].title, on: idx === at ? 'on' : '', at: idx });
        else vis.push({ title: '', on: '', at: -1 });
      }
      if (PAGE) PAGE._pickSlots = vis.map(function (v) { return v.at; });
      PAGE.setData({
        showPick: !split,
        showSplit: split,
        showBack: false,
        showScore: false,
        showPic: false,
        scoreSrc: '',
        showHint: false,
        showWait: !!ST.busyWait,
        waitDots: ST.waitDots || '·',
        line1: split ? ('每页 ' + lines + ' 行') : '选曲',
        line2: title,
        line3: split ? (ST.splitNote || '前后滑改行数，单击开始，双击返回') : (songs.length > 1 ? '前后滑换曲，单击进入，双击离开' : '单击选中。双击离开'),
        pick0: vis[0].title,
        pick1: vis[1].title,
        pick2: vis[2].title,
        pick3: vis[3].title,
        pickOn0: vis[0].on,
        pickOn1: vis[1].on,
        pickOn2: vis[2].on,
        pickOn3: vis[3].on,
        lineIs2: lines === 2 ? 'on' : '',
        lineIs3: lines === 3 ? 'on' : ''
      });
    }
    ST._scoreCx = null;
    paintStage();
    return;
  }
  if (ST.phase === 'show' && hasScore()) {
    if (PAGE && PAGE.setData) {
      PAGE.setData({
        showPick: false,
        showSplit: false,
        showBack: false,
        showScore: true,
        showPic: true,
        scoreSrc: ST.preset[ST.idx] || '',
        showHint: false,
        showWait: false,
        lineTag: (ST.linesPerScreen === 2 ? 2 : 3) + '行',
        micText: ST.micText || '',
        micBtn: (PAGE && PAGE._playing) ? '' : ((ST.micText === '校准' || ST.micText === '开始演奏') ? 'on' : ''),
        hudTip: headTip(),
        scr: ST.idx + 1,
        scrTotal: ST.preset.length
      });
    }
    return;
  }
  publishHint();
  let cx = null;
  try { cx = wx.createCanvasContext('score'); } catch (e) { log('canvas ctx: ' + e); return; }
  if (!cx) { log('canvas ctx 为空'); return; }
  try {
    paintScreen(cx);
  } catch (e) {
    log('渲染失败: ' + (e && e.message ? e.message : e));
  }
}

function paintScreen(cx) {
  cx.fillStyle = '#000000';
  cx.fillRect(0, 0, SW, SH);

  const sc = ST.screens[ST.idx];
  if (ST.phase !== 'show' || !hasScore() || !sc || !sc.length) {
    const lines = String(ST.hint || '导入谱子').split('\n');
    cx.fillStyle = '#40FF5E';
    cx.font = '48px sans-serif';
    cx.textAlign = 'center';
    const lh = 52;
    let y = (SH - lines.length * lh) / 2 + 36;
    for (let i = 0; i < lines.length; i++) {
      cx.fillText(lines[i], SW / 2, y);
      y += lh;
    }
    cx.textAlign = 'left';
    cx.flush();
    return;
  }

  try { cx.flush(); } catch (e) {}
  const full = cx.getImageData(0, 0, SW, SH);
  const d = full.data;

  const bottom = SH - HINT_H;
  const top = 18;
  const usable = bottom - top - 4;
  const s0 = baseScale();
  const items = sc.map(i => {
    const b = ST.blocks[i];
    return { b, w: (b.x1 - b.x0) * s0, h: (b.y1 - b.y0) * s0 };
  });
  const sumH = items.reduce((s, it) => s + it.h, 0) + GAP * (items.length - 1);
  const fit = Math.min(1, usable / sumH);
  let y = top + (usable - sumH * fit) / 2;
  if (y < top) y = top;

  items.forEach(it => {
    const page = (it.b.pi != null && ST.pages && ST.pages[it.b.pi]) ? ST.pages[it.b.pi] : null;
    const A = page ? page.A : ST.inkA;
    const w = page ? page.w : ST.inkW;
    const h = page ? page.h : ST.inkH;
    const ks = page ? page.scale : ST.scale;
    const dw = Math.max(1, Math.round(it.w * fit));
    const dh = Math.max(1, Math.round(it.h * fit));
    const dx = Math.round((SW - dw) / 2);
    const dy = Math.round(y);
    const drawH = Math.min(dh, bottom - dy);
    if (drawH <= 0 || dy < 0 || dx < 0 || dx + dw > SW) { y += dh + GAP * fit; return; }
    const b = it.b;
    const sx = Math.max(0, b.x0 * ks), sy = Math.max(0, b.y0 * ks);
    const sw = Math.max(1, (b.x1 - b.x0) * ks), sh = Math.max(1, (b.y1 - b.y0) * ks);
    const Larr = page && page.L;
    const bg = (page && page.bgL) || 245;
    // 按原图深浅画绿字。颜色聚类掩膜会把偏灰的谱字抹掉，这里不用它来显示。
    for (let py = 0; py < drawH; py++) {
      const fy = Math.min(sh - 0.001, Math.max(0, (py + 0.5) / dh * sh - 0.5));
      const y0i = fy | 0, ty = fy - y0i;
      const r0 = (y0i + sy) | 0, r1 = Math.min(h - 1, r0 + 1);
      const row0 = r0 * w, row1 = r1 * w;
      let di = ((dy + py) * SW + dx) * 4;
      for (let pxl = 0; pxl < dw; pxl++) {
        const fx = Math.min(sw - 0.001, Math.max(0, (pxl + 0.5) / dw * sw - 0.5));
        const x0i = fx | 0, tx = fx - x0i;
        const c0 = (x0i + sx) | 0, c1 = Math.min(w - 1, c0 + 1);
        let v = 0;
        if (Larr) {
          const l00 = Larr[row0 + c0], l01 = Larr[row0 + c1];
          const l10 = Larr[row1 + c0], l11 = Larr[row1 + c1];
          const lv = (l00 * (1 - tx) + l01 * tx) * (1 - ty) +
                     (l10 * (1 - tx) + l11 * tx) * ty;
          const ink = bg - lv;
          if (ink > 26) v = Math.min(255, ink * 2);
        } else if (A) {
          const a00 = A[row0 + c0], a01 = A[row0 + c1];
          const a10 = A[row1 + c0], a11 = A[row1 + c1];
          v = (a00 * (1 - tx) + a01 * tx) * (1 - ty) +
              (a10 * (1 - tx) + a11 * tx) * ty;
          if (v <= 8) v = 0;
        }
        if (v > 8) {
          d[di] = 0x3d;
          d[di + 1] = 0xff;
          d[di + 2] = 0x5c;
          d[di + 3] = v >= 252 ? 255 : v | 0;
        }
        di += 4;
      }
    }
    y += dh + GAP * fit;
  });
  cx.putImageData(full, 0, 0);
  cx.flush();
}

/* ---------- 谱图加载：fetch assets → 失败退 base64 兜底 ---------- */
async function loadScoreImage() {
  const names = ['/assets/score-1.jpg', '/assets/score-2.jpg', '/assets/score-3.jpg'];
  let n = 0;
  for (let i = 0; i < names.length; i++) {
    try {
      const res = await fetch(names[i]);
      if (!res.ok) continue;
      ST.bitmap = await createImageBitmap(await res.blob());
      ST.imgW = ST.bitmap.width;
      ST.imgH = ST.bitmap.height;
      await analyzeBitmap({ append: n > 0, holdScreens: true });
      n++;
    } catch (e) {
      log('载入失败 ' + names[i]);
    }
  }
  if (n) {
    buildScreens();
    ST.idx = 0;
    ST.inkReady = true;
    ST.status = '';
    log('谱已就绪 ' + n + ' 页 / ' + (ST.melodyRows ? ST.melodyRows.length : 0) + ' 行');
    renderScreen();
    return;
  }
  let blob = null, src = '';
  try {
    const res = await fetch('/assets/score.png');
    if (res.ok) { blob = await res.blob(); src = 'assets/score.png'; }
  } catch (e) { /* 走兜底 */ }
  if (!blob) {
    try {
      const bin = atob(SCORE_B64);
      const bytes = new Uint8Array(bin.length);
      for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
      blob = new Blob([bytes], { type: 'image/png' });
      src = 'score-image.js 兜底';
    } catch (e) {
      ST.status = '谱图加载失败';
      renderScreen();
      return;
    }
  }
  try {
    ST.bitmap = await createImageBitmap(blob);
    ST.imgW = ST.bitmap.width;
    ST.imgH = ST.bitmap.height;
    log('谱图已加载(' + src + '): ' + ST.imgW + 'x' + ST.imgH);
    await analyzeBitmap();
  } catch (e) {
    ST.status = '谱图解码失败';
    log('createImageBitmap 失败: ' + (e && e.message ? e.message : e));
  }
  renderScreen();
}

function pickUtterance(query) {
  if (!query) return '';
  if (typeof query === 'string') return query;
  if (typeof query !== 'object') return '';
  const text = query.utterance || query.text || query.asr || query.asrText || query.voice
    || query.cmd || query.command || query.content || query.message || query.rawText || '';
  if (text) return String(text);
  const keys = Object.keys(query);
  for (let i = 0; i < keys.length; i++) {
    const v = query[keys[i]];
    if (typeof v !== 'string' || !v || v.length > 40 || looksLikeImage(v)) continue;
    if (/拍|行|晚|早|跟随|停止|暂停|拍完/.test(v)) return v;
  }
  return '';
}

function looksLikeImage(text) {
  if (!text || typeof text !== 'string') return false;
  const s = text.trim();
  if (!s) return false;
  if (s.indexOf('data:image') === 0) return true;
  if (s.length > 8000) return false;
  if (s.indexOf('blob:') === 0 || s.indexOf('wxfile:') === 0 || s.indexOf('content:') === 0) return true;
  if (/^https?:\/\//i.test(s)) return true;
  if (/\.(png|jpe?g|webp|gif|bmp)(\?|#|$)/i.test(s)) return true;
  if (s.charAt(0) === '/' && s.indexOf(' ') < 0) return true;
  return false;
}

function collectImageRefs(node, out, depth) {
  if (node == null || depth > 4) return;
  if (typeof node === 'string') {
    if (looksLikeImage(node)) out.push(node);
    return;
  }
  if (typeof Blob !== 'undefined' && node instanceof Blob) { out.push(node); return; }
  if (typeof ArrayBuffer !== 'undefined' && node instanceof ArrayBuffer) { out.push(node); return; }
  if (Array.isArray(node)) {
    for (let i = 0; i < node.length; i++) collectImageRefs(node[i], out, depth + 1);
    return;
  }
  if (typeof node !== 'object') return;
  if (node.data && (node.mimeType || node.type)) { out.push(node); return; }
  const skip = { utterance: 1, text: 1, cmd: 1, command: 1, description: 1, keyword: 1 };
  for (const k in node) {
    if (skip[k]) continue;
    collectImageRefs(node[k], out, depth + 1);
  }
}

function imageKey(ref) {
  if (typeof ref === 'string') return ref.slice(0, 240);
  if (ref && ref.tempFilePath) return String(ref.tempFilePath);
  if (ref && ref.path) return String(ref.path);
  if (ref && ref.url) return String(ref.url);
  if (ref && typeof Blob !== 'undefined' && ref instanceof Blob) return 'blob:' + ref.size + ':' + ref.type;
  if (ref && ref.data && ref.data.byteLength) return 'buf:' + ref.data.byteLength;
  return '';
}

function readLocalFile(path) {
  return new Promise(function (resolve, reject) {
    let fs = null;
    try { fs = (wx && wx.getFileSystemManager) ? wx.getFileSystemManager() : null; } catch (e) { fs = null; }
    if (!fs || !fs.readFile) { reject(new Error('读不到本地图')); return; }
    fs.readFile({
      filePath: path,
      success: function (r) { resolve(r.data); },
      fail: function (e) { reject(e || new Error('读不到本地图')); }
    });
  });
}

function bytesFromB64(b64) {
  const bin = atob(b64);
  const bytes = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i) & 255;
  return bytes;
}

async function bitmapFromB64(b64) {
  return createImageBitmap(new Blob([bytesFromB64(b64)], { type: 'image/jpeg' }));
}

async function bitmapFromPreset(url) {
  return refToBitmap(url);
}

function blitBitmap(cx, bmp, destH) {
  const dh = destH || SH;
  try {
    cx.drawImage(bmp, 0, 0, SW, dh);
    return;
  } catch (e) {}
  const w = bmp.width || SW;
  const h = bmp.height || SH;
  const off = (typeof Canvas === 'function') ? new Canvas(w, h) : null;
  if (!off || !off.getContext) throw new Error('画不上去');
  const oc = off.getContext('2d');
  oc.drawImage(bmp, 0, 0, w, h);
  cx.putImageData(oc.getImageData(0, 0, w, h), 0, 0);
}

async function refToBitmap(ref) {
  if (ref && ref.width && typeof ref.close === 'function') return ref;
  if (typeof Blob !== 'undefined' && ref instanceof Blob) return createImageBitmap(ref);
  if (typeof ArrayBuffer !== 'undefined' && ref instanceof ArrayBuffer) {
    return createImageBitmap(new Blob([ref], { type: 'image/jpeg' }));
  }
  if (ref && ref.data) {
    const buf = ref.data;
    const type = ref.mimeType || ref.type || 'image/jpeg';
    if (typeof Blob !== 'undefined' && buf instanceof Blob) return createImageBitmap(buf);
    return createImageBitmap(new Blob([buf], { type: type }));
  }
  let url = '';
  if (typeof ref === 'string') url = ref;
  else if (ref && ref.tempFilePath) url = String(ref.tempFilePath);
  else if (ref && ref.path) url = String(ref.path);
  else if (ref && (ref.url || ref.src)) url = String(ref.url || ref.src);
  if (!url) throw new Error('没有图片');
  try {
    const res = await fetch(url);
    if (res && res.ok) return createImageBitmap(await res.blob());
  } catch (e) {}
  const data = await readLocalFile(url);
  const type = /\.png(\?|#|$)/i.test(url) ? 'image/png' : 'image/jpeg';
  return createImageBitmap(new Blob([data], { type: type }));
}

function readTune() {
  try {
    const raw = localStorage.getItem('guzheng-tune');
    if (!raw) return;
    const o = JSON.parse(raw);
    if (o && typeof o.delay === 'number') ST.turnDelay = Math.max(0, Math.min(2000, o.delay));
    if (o && (o.lines === 2 || o.lines === 3)) ST.linesPerScreen = o.lines;
  } catch (e) {}
}

function songLayout(song, lines) {
  const bag = (song && song.layouts) || {};
  const key = String(lines || 3);
  if (bag[key]) return bag[key];
  if (bag['3']) return bag['3'];
  const keys = Object.keys(bag);
  return keys.length ? bag[keys[0]] : null;
}

function writeTune() {
  try {
    localStorage.setItem('guzheng-tune', JSON.stringify({
      delay: ST.turnDelay || 0,
      lines: ST.linesPerScreen || 3
    }));
  } catch (e) {}
}

/* ==========================================================================
 * 页面
 * ========================================================================== */
export default {
  data: {
    running: false,
    scr: 1,
    scrTotal: 0,
    showHint: false,
    showPick: true,
    showSplit: false,
    showScore: false,
    showPic: false,
    scoreSrc: '',
    showBack: false,
    micText: '',
    hudTip: '前滑下页 · 后滑上页 · 双击返回',
    busy: false,
    line1: '选曲',
    line2: '发如雪',
    pick0: '',
    pick1: '',
    pick2: '',
    pick3: '',
    pickOn0: '',
    pickOn1: '',
    pickOn2: '',
    pickOn3: '',
    showWait: false,
    waitDots: '·',
    line3: '单击选中。双击离开',
    lineIs2: '',
    lineIs3: 'on',
    lineTag: '3行',
    hostTarget: ''
  },

  _seqRaw: '',
  _rec: null,
  _actx: null,
  _astream: null,
  _analyser: null,
  _pollTimer: 0,
  _lastSeq: null,

  onLoad(query) {
    log('page onLoad · 曲目 ' + ((SONGS && SONGS.length) || 0) + ' ' + ((SONGS || []).map(function (s) { return s.title; }).join('、')));
    PAGE = this;
    readTune();
    this._bootAt = Date.now();
    this._bootUtterance = '';
    this._queued = '';
    ST.pages = [];
    ST.blocks = [];
    ST.screens = [];
    ST.inkReady = false;
    ST.bitmaps = null;
    ST.preset = null;
    ST.phase = 'pick';
    this.showPick();
    this.acceptQuery(query);
    const pending = takeQuery();
    if (pending) this.acceptQuery(pending);
    const self = this;
    setTimeout(function () { self.flushVoice(); }, 200);
    if (query && String(query.shoot) === '1') {
      this._forceShoot = true;
      setTimeout(function () { self.shootScore(); }, 500);
    }
  },

  onTargetChanged(target) {
    this.setData({ hostTarget: target || '' });
    if (target === '_blank' && this._shootWhenBlank && !this._ingesting) {
      this._shootWhenBlank = false;
      this.shootScore();
    }
  },

  onReady() {
    PAGE = this;
    renderScreen();
  },

  onShow(query) {
    PAGE = this;
    this._hidden = false;
    this.acceptQuery(query);
    const pending = takeQuery();
    if (pending) this.acceptQuery(pending);
  },

  onHide() {
    this._hidden = true;
    ST._scoreCx = null;
    try { console.log('[guzheng] page hide ' + ST.phase); } catch (e) {}
    this.stopCommand();
    this.stopMic();
    this.stopHead();
    try { this.setData({ micText: '' }); } catch (e) {}
  },

  acceptQuery(query) {
    if (!query) return;
    const imgs = [];
    collectImageRefs(query, imgs, 0);
    const fresh = [];
    const now = Date.now();
    if (!this._imgSeen) this._imgSeen = {};
    for (let i = 0; i < imgs.length; i++) {
      const key = imageKey(imgs[i]);
      if (key && this._imgSeen[key] && now - this._imgSeen[key] < 4000) continue;
      if (key) this._imgSeen[key] = now;
      fresh.push(imgs[i]);
    }
    if (fresh.length) this.ingestRefs(fresh);
  },

  enqueueVoice(text) {
    const now = Date.now();
    if (!text || (text === this._voiceText && now - (this._voiceAt || 0) < 400)) return;
    this._voiceText = text;
    this._voiceAt = now;
    this._queued = text;
    this.flushVoice();
  },

  flushVoice() {
    if (!this._queued) return;
    const text = this._queued;
    this._queued = '';
    this.applyVoice(text);
  },

  onUnload() {
    this.stopHead();
    this.stopMic();
  },

  /* ---------- 序列 ---------- */
  applySeqText(txt) {
    this._seqRaw = txt;
    const r = parseSeq(txt, 2);   // 1 = D
    if (!r) { ST.status = '序列没解析出来(检查 seq-config.js)'; log('序列没解析出来'); return false; }
    alignInit(r.score);
    FOLLOW.edges = r.edges;
    FOLLOW.vScreen = 0;
    this._lastSeq = r;
    this._screens = [];
    for (let i = 0; i < r.edges.length - 1; i++) this._screens.push(r.score.slice(r.edges[i], r.edges[i + 1]));
    this.setData({ scrTotal: Math.min(r.edges.length - 1, ST.screens.length || r.edges.length - 1), scr: 1 });
    log('序列就绪：' + r.score.length + ' 音 / ' + (r.edges.length - 1) + ' 屏');
    return true;
  },

  /* ---------- 跟随启停（镜腿键 Enter） ---------- */
  toggleFollow() {
    if (ST.phase !== 'show') return;
    if (this.data.running) { this.stopMic(); return; }
    if (!hasScore()) {
      ST.status = '先说「拍琴谱」\n拍到谱才能跟随';
      renderScreen();
      return;
    }
    this.startMic();
  },

  async startMic() {
    if (ST.phase !== 'show' || !this._scoreShown) return;
    if (this._rec || this._astream || this._micStarting) return;
    this._micStarting = true;
    const gen = (this._listenGen || 0) + 1;
    this._listenGen = gen;
    try {
      this._resetEngine();
      this._rateSet = false;
      this._frameErr = false;
      FOLLOW.on = true;
      ST.listening = true;
      let rec = null;
      try {
        rec = (wx && wx.media && wx.media.getRecorderManager) ? wx.media.getRecorderManager() : null;
      } catch (e) { rec = null; }
      if (!rec || !rec.start || !rec.onFrameRecorded) throw new Error('没有 PCM');
      const self = this;
      rec.onFrameRecorded(function (res) {
        try {
          if (gen !== self._listenGen || !self._scoreShown || ST.phase !== 'show' || !FOLLOW.on) return;
          const raw = res && (res.frameBuffer || (res.byteLength ? res : null));
          if (!raw) return;
          const f32 = pcmToFloat(raw);
          if (!f32.length) return;
          if (!self._rateSet) {
            const hz = sampleRateOf(f32.length, FRAME_MS);
            if (hz) {
              self._rateSet = true;
              if (!self._ear || self._ear.sr !== hz) self._ear = createEar(hz);
              log('采样率 ' + hz);
            }
          }
          if (!self._level) self._level = createLevel();
          self.processBlock(levelFrame(self._level, f32));
        } catch (err) {
          if (!self._frameErr) {
            self._frameErr = true;
            log('帧处理 ' + (err && err.message ? err.message : err));
          }
        }
      });
      try {
        rec.onError(function (err) {
          FOLLOW.on = false;
          ST.listening = false;
          log('麦 ' + ((err && (err.errMsg || err.message)) || '') + '，谱留着');
        });
      } catch (e) {}
      await openRecorder(rec);
      this._rec = rec;
      this._micStarting = false;
      this._heard = 0;
      this._level = createLevel();
      const phrase = ST.followScreens && ST.followScreens[FOLLOW.vScreen || 0];
      try { this.setData({ running: true }); } catch (e) {}
      log('开始听 这一屏 ' + (phrase ? phrase.length : 0) + ' 音');
    } catch (e) {
      this._micStarting = false;
      FOLLOW.on = false;
      ST.listening = false;
      log('麦没开，谱留着');
    }
  },

  stopMic() {
    this._listenGen = (this._listenGen || 0) + 1;
    this._micStarting = false;
    FOLLOW.on = false;
    ST.listening = false;
    ST.micText = '';
    try { if (this._rec && this._rec.stop) this._rec.stop(); } catch (e) {}
    this._rec = null;
    if (this._pollTimer) { clearInterval(this._pollTimer); this._pollTimer = 0; }
    try {
      if (this._astream && this._astream.getTracks) {
        const tracks = this._astream.getTracks();
        for (let i = 0; i < tracks.length; i++) tracks[i].stop();
      }
    } catch (e) {}
    this._astream = null;
    try { if (this._proc) this._proc.disconnect(); } catch (e) {}
    this._proc = null;
    try { if (this._analyser) this._analyser.disconnect(); } catch (e) {}
    this._analyser = null;
    try { if (this._actx) this._actx.close(); } catch (e) {}
    this._actx = null;
    this._holdEar = false;
  },

  startHead() {
    if (this._headSensor || this._headOri || ST.phase !== 'show') return;
    this._head = createHeadTurn();
    const self = this;
    const onAngles = function (angles) {
      if (ST.phase !== 'show' || !self._scoreShown || !self._head) return;
      noteHead(self._head, angles);
      if (!self._head.live) return;
      const dir = takeHead(self._head, angles);
      if (!dir) return;
      self.setScreen(ST.idx + dir, dir > 0 ? '平视' : '低头');
    };
    const root = typeof globalThis !== 'undefined' ? globalThis : (typeof window !== 'undefined' ? window : null);
    const Sensor = root && root.AbsoluteOrientationSensor;
    if (typeof Sensor === 'function') {
      try {
        const sensor = new Sensor({ frequency: 20 });
        sensor.addEventListener('reading', function () {
          const q = quatOf(sensor.quaternion);
          if (!q) return;
          onAngles(anglesFromQuat(q[0], q[1], q[2], q[3]));
        });
        sensor.addEventListener('error', function (ev) {
          const msg = ev && ev.error && ev.error.message;
          log('头控 ' + (msg || '传感器没开'));
        });
        const started = sensor.start();
        if (started && started.then) started.catch(function (e) { log('头控 ' + (e && e.message ? e.message : e)); });
        this._headSensor = sensor;
        log('头控已开');
        return;
      } catch (e) {
        log('头控 ' + (e && e.message ? e.message : e));
      }
    }
    if (root && root.addEventListener) {
      this._headOri = function (ev) {
        if (!ev || ev.beta == null) return;
        onAngles({ pitch: ev.beta });
      };
      root.addEventListener('deviceorientation', this._headOri);
      log('头控用方向');
      return;
    }
    log('这副眼镜没读到头的方向，滑动仍可翻页');
  },

  armScoreCorner() {
    if (ST.phase !== 'show' || this._corner) return;
    this._playing = false;
    this._corner = 'cal';
    ST.micText = '校准';
    this._micShown = '校准';
    this.startHead();
    try { this.setData({ micText: '校准', micBtn: 'on', hudTip: headTip() }); } catch (e) {}
  },

  onHudAction() {
    if (ST.phase !== 'show' || !this._scoreShown || this._playing) return;
    if (this._corner !== 'ready') {
      if (!this._head) this.startHead();
      if (!commitHead(this._head)) {
        log('头的方向还没读到');
        return;
      }
      this._corner = 'ready';
      ST.micText = '开始演奏';
      this._micShown = '开始演奏';
      try { this.setData({ micText: '开始演奏', micBtn: 'on' }); } catch (e) {}
      log('基准已记下');
      return;
    }
    this._playing = true;
    this._corner = 'play';
    if (this._head) this._head.live = true;
    ST.micText = '开始演奏';
    try { this.setData({ micText: '开始演奏', micBtn: '', hudTip: headTip() }); } catch (e) {}
    this.startMic();
  },

  stopHead() {
    try { if (this._headSensor && this._headSensor.stop) this._headSensor.stop(); } catch (e) {}
    this._headSensor = null;
    const root = typeof globalThis !== 'undefined' ? globalThis : (typeof window !== 'undefined' ? window : null);
    if (this._headOri && root && root.removeEventListener) root.removeEventListener('deviceorientation', this._headOri);
    this._headOri = null;
    this._head = null;
  },

  _resetEngine() {
    const F = FOLLOW;
    F.streamPos = 0; F.frameIdx = 0; F.flux = []; F.cflux = []; F.cframe = []; F.smoothF = [];
    F._prev = null; F.thr = 0; F.lastOnT = 0;
    F.pend = []; F.onCount = 0; F.blocksSinceUI = 0;
    F.ring.fill(0); F.abs = 0;
    F.path = []; F.obs = [];
    F.lastTurnAt = -1e9; F._lagObs = 0;
    if (this._lastSeq) {
      alignInit(this._lastSeq.score);
      F.edges = this._lastSeq.edges;
    }
    this._ear = createEar(F.sr || 16000);
    this._heard = 0;
    F.vScreen = ST.idx || 0;
  },

  processBlock(chunk) {
    if (!this._scoreShown || ST.phase !== 'show') return;
    if (!this._ear || !FOLLOW.on || !chunk || !chunk.length) return;
    const born = pushSamples(this._ear, chunk);
    if (born && born.length) {
      this._heard = (this._heard || 0) + born.length;
      const note = born[born.length - 1];
      if (this._heard <= 3 || this._heard % 8 === 0) {
        try { console.log('[guzheng] 听到 ' + this._heard + ' midi ' + (note && note.midi)); } catch (e) {}
      }
    } else if (!(this._heard > 0)) {
      let energy = 0;
      for (let i = 0; i < chunk.length; i++) energy += chunk[i] * chunk[i];
      if (Math.sqrt(energy / chunk.length) > 0.01) ST._heardSound = true;
    }
    const screens = (ST.followScreens && ST.followScreens.length) ? ST.followScreens : (this._screens || []);
    if (wantNextScreen(this._ear, screens, FOLLOW.vScreen)) {
      this._heard = 0;
      const target = FOLLOW.vScreen + 1;
      const wait = ST.turnDelay || 0;
      const token = this._turnToken;
      const self = this;
      setTimeout(function () {
        if (token !== self._turnToken || !FOLLOW.on) return;
        self.setScreen(target, 'auto');
      }, wait);
    }
  },

  /* ---------- 屏切换（跟随自动 / 镜腿键手动共用） ---------- */
  showPick() {
    this._scoreShown = false;
    this.stopCommand();
    this.stopMic();
    this.stopHead();
    this._scoreGen = (this._scoreGen || 0) + 1;
    this._laying = false;
    this._splitGo = false;
    ST.busyWait = false;
    this.stopWaitDots();
    ST.splitNote = '';
    ST.phase = 'pick';
    ST.bitmaps = null;
    ST.preset = null;
    ST.idx = 0;
    this._song = null;
    this._splitGo = false;
    renderScreen();
    try {
      if (wx && wx.setNavigationBarTitle) wx.setNavigationBarTitle({ title: '选曲' });
    } catch (e) {}
  },

  chooseAt(i) {
    const n = (SONGS || []).length;
    if (i < 0 || i >= n) return;
    ST.pickAt = i;
    this.chooseCurrent();
  },

  chooseSlot(slot) {
    const slots = this._pickSlots || [];
    const i = slots[slot];
    if (i == null || i < 0) return;
    this.chooseAt(i);
  },

  chooseAt0() { this.chooseSlot(0); },
  chooseAt1() { this.chooseSlot(1); },
  chooseAt2() { this.chooseSlot(2); },
  chooseAt3() { this.chooseSlot(3); },

  chooseCurrent() {
    const song = currentSong();
    if (!song) return;
    this.stopCommand();
    this.stopMic();
    this.stopHead();
    this._song = song;
    ST.songTitle = song.title;
    ST.keyPc = keyPcOf(song.key);
    if (ST.linesPerScreen !== 2) ST.linesPerScreen = 3;
    this._splitGo = false;
    ST.splitNote = '';
    ST.phase = 'split';
    renderScreen();
    try {
      if (wx && wx.setNavigationBarTitle) wx.setNavigationBarTitle({ title: '切分' });
    } catch (e) {}
  },

  nudgePick(dir) {
    const songs = SONGS || [];
    const n = songs.length;
    if (n < 2) return;
    const now = Date.now();
    if (now - (this._pickSwipeAt || 0) < 280) return;
    this._pickSwipeAt = now;
    let i = ST.pickAt || 0;
    const step = dir > 0 ? 1 : -1;
    i = Math.max(0, Math.min(n - 1, i + step));
    if (i === ST.pickAt) return;
    ST.pickAt = i;
    renderScreen();
  },

  setLines(n) {
    const v = n === 2 ? 2 : 3;
    ST.linesPerScreen = v;
    ST.splitNote = '';
    if (this._laying) {
      this._scoreGen = (this._scoreGen || 0) + 1;
      this._laying = false;
      this._splitGo = false;
      ST.busyWait = false;
      this.stopWaitDots();
      this.stopMic();
    }
    writeTune();
    if (ST.phase === 'show') {
      this.backToSplit();
      return;
    }
    ST.phase = 'split';
    renderScreen();
  },

  setLines2() { this.setLines(2); },
  setLines3() { this.setLines(3); },

  nudgeLines(dir) {
    const opts = [2, 3];
    let i = opts.indexOf(ST.linesPerScreen === 2 ? 2 : 3);
    i = Math.max(0, Math.min(opts.length - 1, i + (dir > 0 ? 1 : -1)));
    this.setLines(opts[i]);
  },

  goUp() {
    this._dblAt = Date.now();
    try { console.log('[guzheng] 返回 ' + ST.phase); } catch (e) {}
    if (ST.phase === 'show') { this.backToSplit(); return; }
    if (ST.phase === 'split') { this.showPick(); return; }
    if (this.finish) this.finish();
  },

  backToSplit() {
    this._scoreShown = false;
    this._corner = '';
    this._playing = false;
    this.stopCommand();
    this.stopMic();
    this.stopHead();
    this._scoreGen = (this._scoreGen || 0) + 1;
    this._laying = false;
    this._splitGo = false;
    ST.busyWait = false;
    this.stopWaitDots();
    ST.splitNote = '';
    ST.phase = 'split';
    ST.idx = 0;
    FOLLOW.vScreen = 0;
    renderScreen();
    try {
      if (wx && wx.setNavigationBarTitle) wx.setNavigationBarTitle({ title: '切分' });
    } catch (e) {}
  },

  confirmSplit() {
    if (ST.phase !== 'split' || this._laying || this._splitGo) return;
    this._splitGo = true;
    if (this._tapTimer) { clearTimeout(this._tapTimer); this._tapTimer = 0; }
    this.startScore();
  },

  failSplit(why) {
    this._laying = false;
    this._splitGo = false;
    ST.busyWait = false;
    this.stopWaitDots();
    this.stopMic();
    ST.phase = 'split';
    ST.splitNote = '';
    log('切谱失败 ' + why);
    renderScreen();
  },

  startWaitDots() {
    this.stopWaitDots();
    ST._dotI = 0;
    ST._dotAt = Date.now();
    ST.waitDots = '·';
    const self = this;
    this._dots = setInterval(function () {
      if (!ST.busyWait) { self.stopWaitDots(); return; }
      bumpDots();
    }, 280);
  },

  stopWaitDots() {
    if (this._dots) { clearInterval(this._dots); this._dots = 0; }
  },

  async startScore() {
    const song = this._song || currentSong();
    const lines = ST.linesPerScreen === 2 ? 2 : 3;
    if (!song || this._laying) {
      if (!this._laying) this._splitGo = false;
      return;
    }
    const layout = song.layouts && song.layouts[String(lines)];
    if (!layout || !(layout.screens && layout.screens.length)) {
      this.failSplit('没有这套图');
      return;
    }
    this._laying = true;
    this._song = song;
    this._scoreShown = false;
    ST.songTitle = song.title;
    ST.linesPerScreen = lines;
    ST.preset = layout.screens;
    ST.followScreens = layout.notes || [];
    ST.screens = layout.screens.map(function () { return [0]; });
    ST.blocks = [{ x0: 0, x1: 1, y0: 0, y1: 1 }];
    ST.pages = [{ w: 1 }];
    ST.inkReady = true;
    ST.linesLoaded = lines;
    ST.analyzedId = song.id;
    ST.idx = 0;
    ST.picMiss = false;
    ST.busyWait = false;
    this.stopWaitDots();
    this._laying = false;
    this._splitGo = false;
    try { console.log('[guzheng] 贴上 ' + layout.screens.length + ' 屏 · 每页' + lines + '行'); } catch (e) {}
    this.beginShow();
  },

  noteMic() {
    return;
  },

  armListen() {
    return;
  },

  armBrowserMic() {
    return;
  },

  beginShow() {
    if (!hasScore()) {
      this.showPick();
      return;
    }
    this.stopCommand();
    this._scoreShown = false;
    FOLLOW.on = false;
    ST.phase = 'show';
    ST.hint = '';
    ST.idx = 0;
    FOLLOW.vScreen = 0;
    ST.listening = false;
    ST.micText = '校准';
    this._corner = '';
    this._playing = false;
    renderScreen();
    const self = this;
    const gen = this._scoreGen || 0;
    setTimeout(function () {
      if (ST.phase !== 'show' || self._scoreShown) return;
      if ((self._scoreGen || 0) !== gen && gen) return;
      self._scoreShown = true;
      self.armScoreCorner();
    }, 400);
    try {
      if (wx && wx.setNavigationBarTitle) wx.setNavigationBarTitle({ title: '翻谱' });
    } catch (e) {}
  },

  setScreen(si, why) {
    if (ST.phase !== 'show' || !hasScore()) return;
    this._turnToken = (this._turnToken || 0) + 1;
    const nScr = Math.max(1, (ST.bitmaps && ST.bitmaps.length) || ST.screens.length);
    const v = Math.max(0, Math.min(si, nScr - 1));
    ST.idx = v;
    FOLLOW.vScreen = v;
    if (this._ear) markScreen(this._ear);
    this.setData({
      scr: v + 1,
      showPic: !ST.picMiss,
      scoreSrc: (ST.preset && ST.preset[v]) || ''
    });
    this._heard = 0;
    if (why) {
      try { console.log('[guzheng] ' + why + ' → 第' + (v + 1) + '屏'); } catch (e) {}
    }
    renderScreen();
  },

  scoreReady() {
    if (ST.phase !== 'show') return;
    try { console.log('[guzheng] 图已挂上 ' + ((ST.preset && ST.preset[ST.idx]) || '')); } catch (e) {}
    if (this._scoreShown) return;
    this._scoreShown = true;
    this.armScoreCorner();
  },

  scoreMiss() {
    if (ST.picMiss) return;
    ST.picMiss = true;
    ST._scoreCx = null;
    try { console.log('[guzheng] 图没挂上'); } catch (e) {}
    try { this.setData({ showPic: false }); } catch (e) {}
    const self = this;
    setTimeout(function () { if (ST.phase === 'show') paintPixels(); }, 60);
  },

  _hookAt: 0,
  _swipeAt: 0,
  _swipeDir: '',
  _asr: null,

  keyName(event) {
    if (!event) return '';
    const d = event.detail || null;
    return String(event.code || event.key || (d && (d.code || d.key)) || '');
  },

  arrowDir(event) {
    const code = this.keyName(event);
    if (code === 'ArrowDown' || code === 'ArrowRight' || code === 'Down' || code === 'Right'
        || code === 'BrowserForward' || code === 'MediaTrackNext' || code === 'PageDown') return 1;
    if (code === 'ArrowUp' || code === 'ArrowLeft' || code === 'Up' || code === 'Left'
        || code === 'MediaTrackPrevious' || code === 'PageUp') return -1;
    const d = event && event.detail;
    const which = event && (event.keyCode || event.which || (d && (d.keyCode || d.which)));
    if (which === 40 || which === 39) return 1;
    if (which === 38 || which === 37) return -1;
    return 0;
  },

  isBackKey(event) {
    const code = this.keyName(event);
    if (code === 'Backspace' || code === 'Escape' || code === 'GoBack' || code === 'BrowserBack') return true;
    const which = event && (event.keyCode || event.which);
    return which === 8 || which === 27;
  },

  blockHost(event) {
    try { if (event && event.preventDefault) event.preventDefault(); } catch (e) {}
    try { if (event && event.stopPropagation) event.stopPropagation(); } catch (e) {}
    const d = event && event.detail;
    try { if (d && d.preventDefault) d.preventDefault(); } catch (e) {}
  },

  takeArrow(event) {
    const back = this.isBackKey(event);
    if (back && Date.now() < (this._swallowBackUntil || 0)) {
      this.blockHost(event);
      return true;
    }
    const dir = back ? -1 : this.arrowDir(event);
    if (!dir) return false;
    if (event && event.preventDefault) event.preventDefault();
    if (back && Date.now() - (this._dblAt || 0) < 900) return true;
    if (ST.phase === 'pick') {
      if (back) return true;
      this.nudgePick(dir);
      return true;
    }
    if (ST.phase !== 'split' && ST.phase !== 'show') return true;
    const now = Date.now();
    if (now - this._swipeAt < (back ? 700 : 280)) return true;
    this._swipeAt = now;
    if (ST.phase === 'split') {
      if (back) return true;
      this.nudgeLines(dir);
      return true;
    }
    this.setScreen(ST.idx + dir, '手动');
    return true;
  },

  hold(event) {
    if (ST.phase !== 'show' && ST.phase !== 'split') return;
    try { if (event && event.preventDefault) event.preventDefault(); } catch (e) {}
  },

  noteSwipe() {
    this._swiped = true;
    if (this._dblTimer) { clearTimeout(this._dblTimer); this._dblTimer = 0; }
    if (this._tapTimer) { clearTimeout(this._tapTimer); this._tapTimer = 0; }
    this._dbl = false;
    if (ST.phase !== 'show') this.stopMic();
  },

  fireDouble() {
    if (this._dblTimer) { clearTimeout(this._dblTimer); this._dblTimer = 0; }
    if (this._tapTimer) { clearTimeout(this._tapTimer); this._tapTimer = 0; }
    this._dbl = false;
    this._hookAt = 0;
    this._swiped = false;
    if (Date.now() - (this._dblAt || 0) < 350) return;
    this.goUp();
  },

  takeBack(event) {
    if (!this.isBackKey(event)) return false;
    this.blockHost(event);
    if (Date.now() < (this._swallowBackUntil || 0)) return true;
    if (this._swiped) return true;
    const hooked = this._hookAt && (Date.now() - this._hookAt < 700);
    if (this._dbl || this._dblTimer || hooked) {
      this.fireDouble();
      return true;
    }
    return false;
  },

  onKeyDown(event) {
    this.hold(event);
    const code = this.keyName(event);
    try { console.log('[guzheng] down ' + code + ' ' + ST.phase); } catch (e) {}
    if (code === 'GlobalHook') {
      const now = Date.now();
      if (now - (this._hookAt || 0) < 550 && !this._swiped) {
        this._hookAt = 0;
        this._dbl = true;
        this._swallowBackUntil = now + 900;
        if (this._tapTimer) { clearTimeout(this._tapTimer); this._tapTimer = 0; }
        const self = this;
        if (this._dblTimer) clearTimeout(this._dblTimer);
        this._dblTimer = setTimeout(function () {
          self._dblTimer = 0;
          if (self._swiped) { self._swiped = false; self._dbl = false; return; }
          self.fireDouble();
        }, 180);
        return;
      }
      this._dbl = false;
      this._swiped = false;
      this._hookAt = now;
      return;
    }
    if (code === 'Enter' && ST.phase === 'split') {
      this.confirmSplit();
      return;
    }
    if (this.takeBack(event)) return;
    if (this.takeArrow(event) && !this.isBackKey(event)) this.noteSwipe();
  },

  onKeyUp(event) {
    const code = this.keyName(event);
    if (this.isBackKey(event) || code === 'GlobalHook') this.blockHost(event);
    this.hold(event);
    const now = Date.now();
    try { console.log('[guzheng] up ' + code + ' ' + ST.phase); } catch (e) {}
    if (code === 'GlobalHook') { this.armTempleShot(); return; }
    if (this.takeBack(event)) return;
    if (this.takeArrow(event)) {
      if (!this.isBackKey(event)) this.noteSwipe();
      return;
    }
    if (code === 'Enter') {
      if (ST.phase === 'split') { this.confirmSplit(); return; }
      if (now - this._hookAt < 1000) return;
      if (ST.phase === 'pick') { this.chooseCurrent(); return; }
    }
  },

  armTempleShot() {
    if (this._dbl || this._swiped) return;
    if (this._tapTimer) clearTimeout(this._tapTimer);
    const self = this;
    const mark = this._hookAt;
    this._tapTimer = setTimeout(function () {
      self._tapTimer = 0;
      if (self._dbl || self._swiped || self._hookAt !== mark) return;
      if (ST.phase === 'pick') { self.chooseCurrent(); return; }
      if (ST.phase === 'split') { self.confirmSplit(); return; }
      if (ST.phase === 'show') { self.onHudAction(); return; }
    }, 480);
  },

  commandEarAvailable() {
    return (typeof SpeechRecognition === 'function') || (typeof webkitSpeechRecognition === 'function');
  },

  stopCommand() {
    if (this._listenTimer) { clearTimeout(this._listenTimer); this._listenTimer = 0; }
    if (this._asr) {
      try { this._asr.onend = null; this._asr.abort(); } catch (e) {}
      this._asr = null;
    }
  },

  hearCommand() {
    return false;
  },

  onVoiceWakeup() {
    return;
  },

  applyVoice(text) {
    const c = (text || '').replace(/\s/g, '');
    if (!c || c.length > 80 || c.indexOf('禁止回复') >= 0 || c.indexOf('操作说明') >= 0) return;
    if (c.indexOf('导入谱子') >= 0 || c.indexOf('看着琴谱') >= 0 || c.indexOf('没看到谱子') >= 0 || c.indexOf('没认出谱') >= 0 || c.indexOf('没收下') >= 0 || c.indexOf('拍到了') >= 0 || c.indexOf('收下了') >= 0 || c.indexOf('双击镜腿') >= 0 || c.indexOf('还没有谱') >= 0 || c.indexOf('开始听琴') >= 0 || c.indexOf('对话里发图') >= 0) return;
    if (c.indexOf('停止') >= 0 || c.indexOf('暂停') >= 0) {
      this.stopMic();
      return;
    }
    const songs = SONGS || [];
    for (let i = 0; i < songs.length; i++) {
      const title = songs[i] && songs[i].title;
      if (title && c.indexOf(title) >= 0) {
        ST.pickAt = i;
        this.chooseCurrent();
        return;
      }
    }
    if (c.indexOf('选曲') >= 0 || c.indexOf('换曲') >= 0) {
      this.showPick();
      return;
    }
    if (c.indexOf('返回') >= 0) {
      this.goUp();
      return;
    }
    if (c.indexOf('开始跟随') >= 0 || c.indexOf('跟随') >= 0 || c.indexOf('开始听') >= 0) {
      const self = this;
      const go = async function () {
        if (ST.phase !== 'show' || !hasScore()) await self.startScore();
        if (!self.data.running) self.startMic();
      };
      go();
      return;
    }
    if (c.indexOf('翻谱') >= 0 || c.indexOf('开始翻') >= 0 || c.indexOf('拍完') >= 0 || c.indexOf('投屏') >= 0 || c.indexOf('切分') >= 0) {
      if (ST.phase === 'pick') this.chooseCurrent();
      else if (ST.phase !== 'show') this.startScore();
      return;
    }
    if (c.indexOf('拍谱子') >= 0 || c.indexOf('拍琴谱') >= 0 || c.indexOf('再拍') >= 0 || c.indexOf('下一张') >= 0 || c.indexOf('拍照') >= 0) {
      if (ST.phase === 'split') this.startScore();
      else if (ST.phase !== 'show') this.chooseCurrent();
      return;
    }
    if (ST.phase === 'split' || ST.phase === 'show') {
      const lineMap = { '二': 2, '两': 2, '三': 3, '四': 4 };
      for (const k in lineMap) {
        if (c.indexOf(k + '行') >= 0) {
          this.setLines(lineMap[k]);
          return;
        }
      }
    }
    if (ST.phase !== 'show') return;
    if (c.indexOf('晚') >= 0) {
      ST.turnDelay = Math.min(2000, (ST.turnDelay || 0) + 50);
      writeTune();
      log('翻页延迟 ' + ST.turnDelay + ' 毫秒');
      return;
    }
    if (c.indexOf('早') >= 0) {
      ST.turnDelay = Math.max(0, (ST.turnDelay || 0) - 50);
      writeTune();
      log('翻页延迟 ' + ST.turnDelay + ' 毫秒');
      return;
    }
    if (c.indexOf('停止') >= 0 || c.indexOf('暂停') >= 0) {
      this.stopMic();
      return;
    }
  },

  async shootScore() {
    if (this._ingesting) return;
    const inCard = this.data.hostTarget === '_current';
    if (inCard && !this._forceShoot) {
      this._shootWhenBlank = true;
      const opened = openBlankToShoot();
      ST.hint = opened ? '导入谱子\n进入全屏再拍' : '导入谱子\n先双击全屏';
      renderScreen();
      return;
    }
    this._ingesting = true;
    this.stopCommand();
    if (this.data.running) this.stopMic();
    const snap = {
      pages: (ST.pages || []).slice(),
      blocks: (ST.blocks || []).slice(),
      melody: (ST.melodyRows || []).slice(),
      screens: (ST.screens || []).slice(),
      inkReady: ST.inkReady
    };
    try {
      do {
        this._again = false;
        const shot = await grabScoreFrame();
        ST.bitmap = (shot && shot.width) ? shot : await createImageBitmap(shot);
        ST.imgW = ST.bitmap.width;
        ST.imgH = ST.bitmap.height;
        ST.phase = 'import';
        ST.hint = '谱子切分中';
        this.setData({ busy: true });
        renderScreen();
        await new Promise(function (resolve) { setTimeout(resolve, 80); });
        if (frameIsBlurry(ST.bitmap)) {
          ST.hint = '画面太糊了，没切成\n单击镜腿再拍';
          renderScreen();
          continue;
        }
        await analyzeBitmap({ append: snap.pages.length > 0, holdScreens: true, skipMelody: true });
        buildScreens();
        const gained = pageKept(snap);
        if (!gained) {
          ST.pages = snap.pages;
          ST.blocks = snap.blocks;
          ST.melodyRows = snap.melody;
          ST.screens = snap.screens;
          ST.inkReady = snap.inkReady;
          ST.hint = '画面太糊了，没切成\n单击镜腿再拍';
          renderScreen();
        } else {
          ST.inkReady = true;
          snap.pages = (ST.pages || []).slice();
          snap.blocks = (ST.blocks || []).slice();
          snap.melody = (ST.melodyRows || []).slice();
          snap.screens = (ST.screens || []).slice();
          snap.inkReady = true;
          this.beginShow();
        }
      } while (this._again);
    } catch (e) {
      ST.pages = snap.pages;
      ST.blocks = snap.blocks;
      ST.melodyRows = snap.melody;
      ST.screens = snap.screens;
      ST.inkReady = snap.inkReady;
      const msg = (e && (e.errMsg || e.message)) ? (e.errMsg || e.message) : String(e || '');
      log('取帧失败: ' + msg);
      if (!this._askedBlank && !this._forceShoot) {
        this._askedBlank = true;
        this._shootWhenBlank = true;
        if (openBlankToShoot()) {
          ST.hint = '导入谱子\n进入全屏再拍';
          renderScreen();
          this.setData({ busy: false });
          this._ingesting = false;
          this.hearCommand(false);
          return;
        }
      }
      ST.hint = '导入谱子\n' + (msg ? msg.slice(0, 14) : '没看到谱子');
      renderScreen();
    }
    this.setData({ busy: false });
    this._ingesting = false;
    this.hearCommand(false);
  },

  async ingestRefs(refs) {
    log('这版用包内预设图');
    return;
    const list = refs || [];
    if (!list.length) return;
    if (this._ingesting) {
      this._imgQueue = (this._imgQueue || []).concat(list);
      return;
    }
    this._ingesting = true;
    if (this.data.running) this.stopMic();
    const snap = {
      pages: (ST.pages || []).slice(),
      blocks: (ST.blocks || []).slice(),
      melody: (ST.melodyRows || []).slice(),
      screens: (ST.screens || []).slice(),
      inkReady: ST.inkReady
    };
    let got = false;
    try {
      let batch = list.slice();
      while (batch.length) {
        for (let i = 0; i < batch.length; i++) {
          const bitmap = await refToBitmap(batch[i]);
          ST.bitmap = (bitmap && bitmap.width) ? bitmap : await createImageBitmap(bitmap);
          ST.imgW = ST.bitmap.width;
          ST.imgH = ST.bitmap.height;
          await analyzeBitmap({ append: (snap.pages.length > 0) || got, holdScreens: true });
          buildScreens();
          const gained = pageKept(snap);
          if (!gained) {
            ST.pages = snap.pages.slice();
            ST.blocks = snap.blocks.slice();
            ST.melodyRows = snap.melody.slice();
            ST.screens = snap.screens.slice();
            ST.inkReady = snap.inkReady;
            continue;
          }
          got = true;
          ST.inkReady = true;
          snap.pages = (ST.pages || []).slice();
          snap.blocks = (ST.blocks || []).slice();
          snap.melody = (ST.melodyRows || []).slice();
          snap.screens = (ST.screens || []).slice();
          snap.inkReady = true;
          log('已收 ' + ST.pages.length + ' 张');
        }
        batch = this._imgQueue || [];
        this._imgQueue = [];
      }
      if (got && ST.phase === 'show') {
        ST.hint = '';
        ST.idx = 0;
        FOLLOW.vScreen = 0;
        renderScreen();
      } else if (got) {
        showImportStatus();
        renderScreen();
      } else if (ST.phase !== 'show') {
        ST.hint = '导入谱子\n没认出谱';
        renderScreen();
      }
    } catch (e) {
      ST.pages = snap.pages;
      ST.blocks = snap.blocks;
      ST.melodyRows = snap.melody;
      ST.screens = snap.screens;
      ST.inkReady = snap.inkReady;
      if (ST.phase !== 'show') {
        ST.hint = '导入谱子\n没收下';
        renderScreen();
      }
      const msg = (e && (e.errMsg || e.message)) ? (e.errMsg || e.message) : String(e || '');
      log('收图失败: ' + msg);
      this._imgQueue = [];
    }
    this._ingesting = false;
  }
};
</script>

<page>
  <view class="root">
    <canvas id="score" class="score" width="480" height="352"></canvas>
    <image class="scorepic" ink:if="{{showPic}}" src="{{scoreSrc}}" mode="aspectFit" bindload="scoreReady" binderror="scoreMiss"></image>
    <text class="linetag" ink:if="{{showScore}}">{{lineTag}}</text>
    <view class="panel" ink:if="{{showPick}}">
      <text class="title">{{line1}}</text>
      <view class="pickline {{pickOn0}}" ink:if="{{pick0}}" bindtap="chooseAt0"><text class="pickname">{{pick0}}</text></view>
      <view class="pickline {{pickOn1}}" ink:if="{{pick1}}" bindtap="chooseAt1"><text class="pickname">{{pick1}}</text></view>
      <view class="pickline {{pickOn2}}" ink:if="{{pick2}}" bindtap="chooseAt2"><text class="pickname">{{pick2}}</text></view>
      <view class="pickline {{pickOn3}}" ink:if="{{pick3}}" bindtap="chooseAt3"><text class="pickname">{{pick3}}</text></view>
      <text class="sub">{{line3}}</text>
    </view>
    <view class="panel" ink:if="{{showSplit}}">
      <text class="title">{{line1}}</text>
      <text class="sub">{{line2}}</text>
      <text class="wait" ink:if="{{showWait}}">{{waitDots}}</text>
      <view class="row">
        <view class="cell small {{lineIs2}}" bindtap="setLines2"><text class="big">2行</text></view>
        <view class="cell small {{lineIs3}}" bindtap="setLines3"><text class="big">3行</text></view>
      </view>
      <text class="sub">{{line3}}</text>
    </view>
    <view class="hud" ink:if="{{showScore}}">
      <text class="hudmic {{micBtn}}" bindtap="onHudAction">{{micText}}</text>
      <text class="hudtip">{{hudTip}}</text>
      <text class="hudpage">{{scr}}/{{scrTotal}}</text>
    </view>
    <canvas id="workcv" class="off" width="2" height="2"></canvas>
  </view>
</page>

<style>
.root {
  width: 480px; height: 352px;
  background: #000;
  position: relative;
  overflow: hidden;
}
.score { width: 480px; height: 352px; }
.linetag {
  position: absolute;
  left: 8px;
  top: 2px;
  color: #40FF5E;
  font-size: 13px;
  z-index: 3;
}
.scorepic {
  position: absolute;
  left: 0;
  top: 0;
  width: 480px;
  height: 330px;
  z-index: 1;
}
.hud {
  position: absolute;
  left: 0;
  bottom: 0;
  width: 480px;
  height: 22px;
  background: #000000;
  display: flex;
  flex-direction: row;
  align-items: center;
  justify-content: space-between;
  z-index: 3;
}
.hudmic, .hudtip, .hudpage {
  color: #40FF5E;
  font-size: 13px;
  line-height: 22px;
}
.hudmic { width: 88px; text-align: left; margin-left: 6px; font-size: 14px; }
.hudmic.on {
  border: 1px solid #40FF5E;
  border-radius: 6px;
  text-align: center;
  line-height: 20px;
}
.hudtip { width: 312px; text-align: center; }
.hudpage { width: 48px; text-align: right; margin-right: 8px; }
.panel {
  position: absolute;
  left: 0;
  top: 0;
  width: 480px;
  height: 352px;
  z-index: 2;
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  background: #000000;
}
.title {
  color: #40FF5E;
  font-size: 36px;
  margin-bottom: 22px;
}
.row {
  width: 400px;
  display: flex;
  flex-direction: row;
  justify-content: space-between;
  align-items: center;
}
.cell {
  width: 280px;
  height: 64px;
  margin-top: 8px;
  border: 2px solid #2a4a30;
  border-radius: 12px;
  background: transparent;
  display: flex;
  align-items: center;
  justify-content: center;
}
.cell.small { width: 168px; height: 64px; margin-top: 0; }
.cell.small .big { color: #2f5a3c; }
.cell.on { border-color: #40FF5E; }
.cell.on .big { color: #40FF5E; }
.pickline {
  width: 300px;
  height: 46px;
  margin-top: 8px;
  border: 2px solid #2a4a30;
  border-radius: 12px;
  display: flex;
  align-items: center;
  justify-content: center;
}
.pickname { color: #2f5a3c; font-size: 24px; }
.pickline.on { border-color: #40FF5E; }
.pickline.on .pickname { color: #40FF5E; }
.wait {
  color: #40FF5E;
  font-size: 32px;
  letter-spacing: 6px;
  height: 36px;
  line-height: 36px;
  margin-top: 6px;
}
.big { color: #40FF5E; font-size: 28px; }
.sub {
  color: #4f7a5a;
  font-size: 16px;
  margin-top: 14px;
  margin-bottom: 14px;
}
.off {
  position: absolute;
  left: -10000px;
  top: 0;
  width: 450px; height: 2000px;
  visibility: hidden;
}
</style>
