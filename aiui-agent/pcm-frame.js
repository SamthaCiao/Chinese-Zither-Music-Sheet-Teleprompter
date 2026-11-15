/**
 * 眼镜麦交来的一帧。乐奇文档写的是去掉 WAV 头的原始 PCM，常见是 16 位整数。
 * 有的运行时会给 [-1, 1] 的浮点。两种都收成浮点，后面的听音只认这一种。
 */
export function pcmToFloat(frame) {
  const ab = asArrayBuffer(frame);
  if (!ab || ab.byteLength < 2) return new Float32Array(0);
  const n16 = ab.byteLength >> 1;
  const i16 = new Int16Array(ab.slice(0), 0, n16);
  const asInt = new Float32Array(n16);
  for (let i = 0; i < n16; i++) asInt[i] = i16[i] / 32768;
  if (ab.byteLength % 4 !== 0 || ab.byteLength < 32) return asInt;
  const f32 = new Float32Array(ab.slice(0));
  let peak = 0;
  for (let i = 0; i < f32.length; i++) {
    const v = f32[i];
    if (v !== v || v === Infinity || v === -Infinity) return asInt;
    const a = v < 0 ? -v : v;
    if (a > peak) peak = a;
  }
  if (peak < 1e-8 || peak >= 4) return asInt;
  if (roughness(f32) + 0.05 < roughness(asInt)) return f32;
  return asInt;
}

function roughness(x) {
  if (x.length < 3) return 1;
  let peak = 1e-9;
  let jump = 0;
  for (let i = 0; i < x.length; i++) {
    const a = x[i] < 0 ? -x[i] : x[i];
    if (a > peak) peak = a;
  }
  for (let i = 1; i < x.length; i++) jump += Math.abs(x[i] - x[i - 1]);
  return jump / (peak * (x.length - 1));
}

function asArrayBuffer(frame) {
  if (!frame) return null;
  if (typeof frame === 'string') {
    const bin = typeof atob === 'function' ? atob(frame) : '';
    if (!bin) return null;
    const u = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) u[i] = bin.charCodeAt(i) & 255;
    return u.buffer;
  }
  if (frame instanceof ArrayBuffer) return frame;
  if (frame.buffer && frame.byteLength != null) {
    const start = frame.byteOffset || 0;
    return frame.buffer.slice(start, start + frame.byteLength);
  }
  return null;
}

/** 这一帧有多少个采样、帧间隔是多少毫秒，推一个接近的采样率。对不上就返回 0。 */
export function sampleRateOf(sampleCount, frameMs) {
  if (!sampleCount || !frameMs) return 0;
  const raw = sampleCount / (frameMs / 1000);
  const known = [8000, 16000, 22050, 24000, 32000, 44100, 48000];
  let best = 0;
  let err = 1;
  for (let i = 0; i < known.length; i++) {
    const d = Math.abs(raw - known[i]) / known[i];
    if (d < err) { err = d; best = known[i]; }
  }
  return err < 0.08 ? best : 0;
}

/**
 * 手机外放进眼镜麦时往往偏轻。按最近几帧的峰值把轻的声音抬到能测音高的音量。
 * 已经够响的不放大。纯静音不放大，避免把底噪抬成一个音。
 */
export function createLevel() {
  return { peak: 0 };
}

export function levelFrame(state, chunk) {
  if (!chunk || !chunk.length) return chunk;
  let peak = 0;
  for (let i = 0; i < chunk.length; i++) {
    const a = chunk[i] < 0 ? -chunk[i] : chunk[i];
    if (a > peak) peak = a;
  }
  state.peak = state.peak ? state.peak * 0.85 + peak * 0.15 : peak;
  if (state.peak < 0.004 || state.peak > 0.35) return chunk;
  const g = Math.min(8, 0.35 / state.peak);
  if (g < 1.05) return chunk;
  const out = new Float32Array(chunk.length);
  for (let i = 0; i < chunk.length; i++) out[i] = chunk[i] * g;
  return out;
}
