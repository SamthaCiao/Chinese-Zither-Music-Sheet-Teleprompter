/**
 * 换一首谱时，在电脑上调用的入口。眼镜运行时只认 follow-engine.js。
 *
 * 边缘音可以是本程序从谱图读出来的，也可以是别的模型交来的。
 * 交来的格式，每一屏一条，顺序跟切好的屏一致：
 *   "5531"          简谱数字，0 是休止
 *   [5, 5, 3, 1]    唱名 1–7
 *   [69, 69, 66, 62] 已经是 MIDI
 *
 * prepareEdges(edges, key) 得到眼镜要跟的音，以及每条边缘音的合成采样。
 * 合成采样用来核对「这段音能不能触发翻页」，不装进眼镜。
 */
import { midisOf } from '../aiui-agent/jianpu-read.js';
import { createEar, pushSamples, wantNextScreen } from '../aiui-agent/follow-engine.js';

const KEY = { C: 0, D: 2, E: 4, F: 5, G: 7, A: 9, B: 11 };

/** 调名换成简谱 1 的音级。D 调是 2。不认识的调按 D。 */
export function keyPcOf(name) {
  if (typeof name === 'number') return name;
  const k = String(name || 'D').trim().toUpperCase().replace(/调$/, '');
  return KEY[k] == null ? 2 : KEY[k];
}

/** 一条边缘音收成 MIDI。1 的音高按 key。休止符丢掉。 */
export function notesFromEdge(edge, key) {
  const keyPc = keyPcOf(key);
  if (edge == null) return [];
  if (typeof edge === 'string') return midisOf(edge, keyPc);
  if (!edge.length) return [];
  const nums = edge.map((n) => Number(n));
  if (nums.every((n) => n >= 0 && n <= 7)) return midisOf(nums.join(''), keyPc);
  return nums.map((n) => n | 0);
}

/**
 * 把一组边缘音做成眼镜用的音序，并为每一条合成标准音。
 * edges 与切好的屏一一对应，最后一屏也可以给，但跟随时不会再翻。
 */
export function prepareEdges(edges, key) {
  const notes = (edges || []).map((edge) => notesFromEdge(edge, key));
  const synth = notes.map((midis) => synthPhrase(midis, { cents: true, chord: true }).pcm);
  return { notes, synth };
}

/** 按事件合成拨弦。事件是 { t, midi, cents, chord }。返回 16 kHz 单声道浮点。 */
export function synthEvents(events, sampleRate, noteSeconds) {
  const sr = sampleRate || 16000;
  const note = noteSeconds || 0.2;
  let end = 0.4;
  (events || []).forEach((e) => { end = Math.max(end, e.t + 0.45); });
  const n = Math.ceil(end * sr);
  const x = new Float32Array(n);
  (events || []).forEach((e) => {
    const f = 440 * 2 ** ((e.midi - 69) / 12 + (e.cents || 0) / 1200);
    const a0 = Math.max(0, Math.round(e.t * sr));
    const len = Math.min(n - a0, Math.round(note * sr));
    for (let i = 0; i < len; i++) {
      const te = i / sr;
      let s = 0;
      for (let h = 1; h <= 5; h++) s += Math.exp(-te * (8 + 3 * h)) * Math.sin(2 * Math.PI * f * h * te) / h;
      x[a0 + i] += s;
      if (e.chord) {
        const fc = f * 2 ** (-7 / 12);
        let c = 0;
        for (let h = 1; h <= 3; h++) c += Math.exp(-te * (7 + 3 * h)) * Math.sin(2 * Math.PI * fc * h * te) / h;
        x[a0 + i] += 0.22 * c;
      }
    }
  });
  let peak = 1e-9;
  for (let i = 0; i < n; i++) peak = Math.max(peak, Math.abs(x[i]));
  const scale = 0.7 / peak;
  for (let i = 0; i < n; i++) x[i] *= scale;
  return x;
}

/** 把一小节的 MIDI 合成成要检测的那段音。 */
export function synthPhrase(midis, opt) {
  const o = opt || {};
  const gap = o.gap == null ? 0.3 : o.gap;
  let t = o.t0 == null ? 0.25 : o.t0;
  const events = [];
  const marks = [];
  (midis || []).forEach((midi, i) => {
    events.push({
      t,
      midi,
      cents: o.cents ? (i % 2 ? 24 : -20) : 0,
      chord: !!o.chord
    });
    marks.push(t);
    t += gap;
  });
  return { events, marks, end: t, pcm: synthEvents(events, o.sampleRate || 16000) };
}

/**
 * 用跟眼镜同一份翻页函数听一段采样。
 * phrases[i] 是第 i 屏的边缘音。返回每次翻页时最后一个音的时刻。
 */
export function hearPhrase(pcm, phrases, sampleRate) {
  const sr = sampleRate || 16000;
  const ear = createEar(sr);
  const turns = [];
  let screen = 0;
  const hop = 1600;
  for (let i = 0; i < pcm.length; i += hop) {
    pushSamples(ear, pcm.subarray(i, Math.min(pcm.length, i + hop)));
    if (screen < phrases.length && wantNextScreen(ear, phrases, screen)) {
      const last = ear.onsets[ear.onsets.length - 1];
      turns.push(last ? last.t : 0);
      screen += 1;
    }
  }
  return turns;
}
