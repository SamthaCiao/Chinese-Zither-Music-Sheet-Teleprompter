/**
 * 演奏翻页。眼镜页和核对脚本用同一份。不看时钟。
 * 换谱时的边缘音和合成音在 preview/edge-phrase.mjs，不写死在这里。
 * 每 20 毫秒取刚过去的 0.1 秒，自相关只在 240–1000 Hz 里找一个音，收成最近的半音。
 * 同一个音要稳住约 60 毫秒才算弹出来。紧接着飘到旁边半音，算同一个起音。声音断一下再响，才算又一个音。
 * 翻页只认这一屏最后一小节：刚听到的一串音要和这一小节逐个相同。
 * 少一个、多一个在中间、倒着弹、只对上开头两个音，都不翻。
 */

export function createEar(sampleRate) {
  return {
    sr: sampleRate,
    hop: 320,
    frame: 1024,
    ring: new Float32Array(1 << 16),
    mask: (1 << 16) - 1,
    abs: 0,
    pos: 0,
    flux: [],
    prev: null,
    prevChroma: null,
    lastOnT: -1,
    pending: null,
    onsets: [],
    from: 0
  };
}

function fftInplace(re, im) {
  const n = re.length;
  for (let i = 1, j = 0; i < n; i++) {
    let bit = n >> 1;
    for (; j & bit; bit >>= 1) j ^= bit;
    j ^= bit;
    if (i < j) {
      let t = re[i]; re[i] = re[j]; re[j] = t;
      t = im[i]; im[i] = im[j]; im[j] = t;
    }
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
        re[i + k] = ur + vr;
        im[i + k] = ui + vi;
        re[i + k + len / 2] = ur - vr;
        im[i + k + len / 2] = ui - vi;
        const ncr = cr * wr - ci * wi;
        ci = cr * wi + ci * wr;
        cr = ncr;
      }
    }
  }
}

const HAN = new Float32Array(1024);
for (let i = 0; i < 1024; i++) HAN[i] = 0.5 - 0.5 * Math.cos(2 * Math.PI * i / 1023);

function frameMag(ear, start) {
  const n = ear.frame;
  const re = new Float32Array(n);
  const im = new Float32Array(n);
  for (let i = 0; i < n; i++) re[i] = ear.ring[(start + i) & ear.mask] * HAN[i];
  fftInplace(re, im);
  const half = n >> 1;
  const mag = new Float32Array(half);
  for (let k = 1; k < half; k++) mag[k] = Math.hypot(re[k], im[k]);
  return mag;
}

function fluxAt(ear, start) {
  const mag = frameMag(ear, start);
  const half = mag.length;
  if (!ear.prev) ear.prev = new Float32Array(half);
  let s = 0;
  const p = ear.prev;
  for (let k = 1; k < half; k++) {
    const db = Math.log1p(10 * mag[k]);
    const d = db - p[k];
    if (d > 0) s += d;
    p[k] = db;
  }
  ear._mag = mag;
  return s;
}

function hpsMidi(diff, sr, n) {
  const minF = 247;
  const maxF = 1046;
  let bestF = 0;
  let bestS = 0;
  let highF = 0;
  let highS = 0;
  for (let f = minF; f <= maxF; f += 3) {
    const k1 = Math.round(f * n / sr);
    const k2 = Math.round(2 * f * n / sr);
    const k3 = Math.round(3 * f * n / sr);
    if (k3 >= diff.length || k1 < 1) continue;
    const s = diff[k1] * (diff[k2] + diff[k2 - 1] + diff[Math.min(diff.length - 1, k2 + 1)]) * Math.sqrt(diff[k3] + 1);
    if (s > bestS) { bestS = s; bestF = f; }
    if (f >= 370 && s > highS) { highS = s; highF = f; }
  }
  let f0 = bestF;
  if (highF && highS > bestS * 0.35) f0 = highF;
  if (!f0 || bestS <= 0) return 0;
  return Math.round(69 + 12 * Math.log2(f0 / 440));
}

function chromaPc(ear) {
  const mag = ear._mag;
  if (!mag) return 0;
  const prev = ear._prevLin;
  ear._prevLin = Float32Array.from(mag);
  if (!prev) return 0;
  const diff = new Float32Array(mag.length);
  for (let k = 1; k < mag.length; k++) diff[k] = Math.max(0, mag[k] - prev[k]);
  return hpsMidi(diff, ear.sr, ear.frame);
}

function f0(seg, sr, loHz, hiHz) {
  const n = seg.length;
  let m = 0;
  for (let i = 0; i < n; i++) m += seg[i];
  m /= n;
  let rms = 0;
  const x = new Float32Array(n);
  x[0] = seg[0] - m;
  rms += x[0] * x[0];
  for (let i = 1; i < n; i++) {
    const v = seg[i] - m;
    x[i] = v - 0.95 * (seg[i - 1] - m);
    rms += x[i] * x[i];
  }
  if (Math.sqrt(rms / n) < 0.008) return 0;
  const N = 1 << Math.ceil(Math.log2(2 * n));
  const re = new Float32Array(N);
  const im = new Float32Array(N);
  for (let i = 0; i < n; i++) re[i] = x[i] * (0.5 - 0.5 * Math.cos(2 * Math.PI * i / (n - 1)));
  fftInplace(re, im);
  for (let k = 0; k < N; k++) {
    const a = re[k] * re[k] + im[k] * im[k];
    re[k] = a;
    im[k] = 0;
  }
  fftInplace(re, im);
  const ac = new Float64Array(n);
  for (let i = 0; i < n; i++) ac[i] = re[i] / N;
  if (ac[0] <= 0) return 0;
  for (let i = 0; i < n; i++) ac[i] /= ac[0];
  const tauMin = Math.max(2, Math.floor(sr / (hiHz || 1200)));
  const tauMax = Math.min(Math.floor(sr / (loHz || 70)), n - 2);
  if (tauMax <= tauMin + 2) return 0;
  let bestTau = 0;
  let bestV = 0;
  for (let i = tauMin + 1; i < tauMax; i++) {
    if (ac[i] > ac[i - 1] && ac[i] >= ac[i + 1] && ac[i] > 0.15 && ac[i] > bestV) {
      bestV = ac[i];
      bestTau = i;
    }
  }
  if (!bestTau) return 0;
  for (let i = tauMin + 1; i < bestTau; i++) {
    if (ac[i] > ac[i - 1] && ac[i] >= ac[i + 1] && ac[i] >= bestV * 0.88) {
      bestTau = i;
      break;
    }
  }
  let t = bestTau;
  if (t >= 1 && t < n - 1) {
    const a = ac[t - 1], b = ac[t], c = ac[t + 1];
    const den = a - 2 * b + c;
    if (Math.abs(den) > 1e-9) t += 0.5 * (a - c) / den;
  }
  return sr / t;
}

function midiOf(f) {
  return f <= 0 ? 0 : Math.round(69 + 12 * Math.log2(f / 440));
}

function takePitch(ear, sampleAt, loHz, hiHz) {
  const win = Math.round(0.09 * ear.sr);
  if (sampleAt < 0 || ear.abs < sampleAt + win) return 0;
  if (sampleAt < ear.abs - ear.ring.length) return 0;
  const seg = new Float32Array(win);
  for (let i = 0; i < win; i++) seg[i] = ear.ring[(sampleAt + i) & ear.mask];
  return midiOf(f0(seg, ear.sr, loHz, hiHz));
}

function frameRms(ear) {
  const win = Math.round(0.1 * ear.sr);
  if (ear.pos < win) return 0;
  let s = 0;
  const start = ear.pos - win;
  for (let i = 0; i < win; i++) {
    const v = ear.ring[(start + i) & ear.mask];
    s += v * v;
  }
  return Math.sqrt(s / win);
}

/** 喂一段连续采样。返回新听到的音。翻页不看这些音的时刻。 */
export function pushSamples(ear, chunk) {
  const born = [];
  for (let i = 0; i < chunk.length; i++) ear.ring[(ear.abs + i) & ear.mask] = chunk[i];
  ear.abs += chunk.length;
  while (ear.pos + ear.hop <= ear.abs) {
    ear.pos += ear.hop;
    const midi = melodyFrame(ear);
    const rms = frameRms(ear);
    if (midi > 0 && rms > 0.012) {
      const pc = ((midi % 12) + 12) % 12;
      ear.gap = 0;
      if (ear.latched && ear.holdPc === pc && ear.trough > 0 && rms > ear.trough * 2.4 && (ear.holdN || 0) > 6) {
        ear.latched = false;
        ear.holdN = 0;
      }
      if (ear.latched) ear.trough = Math.min(ear.trough || rms, rms);
      else ear.trough = rms;
      if (ear.holdPc === pc) ear.holdN = (ear.holdN || 0) + 1;
      else { ear.holdPc = pc; ear.holdN = 1; ear.latched = false; }
      if (ear.holdN === 3 && !ear.latched) {
        ear.latched = true;
        const t = ear.pos / ear.sr;
        const prev = ear.onsets[ear.onsets.length - 1];
        if (prev && t - prev.t < 0.09 && Math.abs(midi - prev.midi) === 1) {
          prev.t = t;
          prev.midi = midi;
          prev.pc = pc;
        } else {
          const hit = { t, midi, pc };
          ear.onsets.push(hit);
          born.push(hit);
        }
      }
    } else {
      ear.gap = (ear.gap || 0) + 1;
      if (ear.gap >= 2) {
        ear.holdN = 0;
        ear.latched = false;
      }
    }
  }
  return born;
}

function melodyFrame(ear) {
  const win = Math.round(0.1 * ear.sr);
  const end = ear.pos;
  if (end < win) return 0;
  const seg = new Float32Array(win);
  const start = end - win;
  for (let i = 0; i < win; i++) seg[i] = ear.ring[(start + i) & ear.mask];
  return midiOf(f0(seg, ear.sr, 240, 1000));
}

function resolvePending(ear, born) {
  const win = Math.round(0.09 * ear.sr);
  if (!ear.pending || ear.abs < ear.pending.at + win) return;
  const wide = takePitch(ear, ear.pending.at, 70, 1200);
  const mel = takePitch(ear, ear.pending.at, 247, 1175);
  const t = ear.pending.t;
  ear.pending = null;
  const midi = wide || mel;
  if (midi > 0) {
    const pc = ((mel || midi) % 12 + 12) % 12;
    const prev = ear.onsets[ear.onsets.length - 1];
    if (prev && prev.pc === pc && t - prev.t < 0.16) return;
    const hit = { t, midi, pc };
    ear.onsets.push(hit);
    born.push(hit);
  }
}

function pcOf(n) {
  return ((n % 12) + 12) % 12;
}

function tailIsPhrase(pcs, target, end) {
  const n = target.length;
  const s = end - n + 1;
  if (s < 0 || pcs[end] !== target[n - 1]) return false;
  for (let k = 0; k < n; k++) if (pcs[s + k] !== target[k]) return false;
  return true;
}

/** 刚听到的音，末尾正好是这一小节，不多也不少。后面紧跟一个杂音时，仍算这一小节已经听完。 */
function phraseClosed(heard, phrase) {
  const target = [];
  for (let i = 0; i < phrase.length; i++) target.push(pcOf(phrase[i]));
  const n = target.length;
  if (n < 4 || heard.length < n) return false;
  const pcs = [];
  for (let i = 0; i < heard.length; i++) {
    const h = heard[i];
    pcs.push(h.pc != null ? h.pc : pcOf(h.midi));
  }
  const last = pcs.length - 1;
  if (tailIsPhrase(pcs, target, last)) return true;
  return last > 0 && tailIsPhrase(pcs, target, last - 1);
}

/**
 * screenNotes[i] 是这一屏翻页前那一小节的音（MIDI）。
 * 听完这一小节才翻。已经在最后一屏则保持。不看时间。
 */
export function wantNextScreen(ear, screenNotes, screenIndex) {
  const phrase = screenNotes[screenIndex];
  if (!phrase || phrase.length < 4 || screenIndex >= screenNotes.length - 1) return false;
  const heard = ear.onsets.slice(ear.from || 0);
  if (!phraseClosed(heard, phrase)) return false;
  ear.from = ear.onsets.length;
  return true;
}

export function markScreen(ear) {
  ear.from = ear.onsets.length;
}
