/**
 * 基准是按下「校准」时正在看琴弦的仰角，不是进谱时的朝向。
 * 按下「开始演奏」之后才根据仰角翻页。没开始之前，头怎么动都不翻。
 */
export function createHeadTurn() {
  return {
    zeroP: null,
    locked: false,
    arm: 0,
    sum: 0,
    n: 0,
    fresh: false,
    up: 14,
    down: 16,
    back: 8
  };
}

/** 记下最近几帧仰角，供按下校准时取「正在看琴弦」的角度。 */
export function noteHead(state, angles) {
  if (!state || !angles) return;
  const pitch = angles.pitch;
  if (pitch == null || pitch !== pitch) return;
  if (!state.recent) state.recent = [];
  state.recent.push(pitch);
  if (state.recent.length > 6) state.recent.shift();
}

/** 用按下按钮时已经读到的仰角当基准。方向还没读到就返回 false。 */
export function commitHead(state) {
  if (!state || !state.recent || state.recent.length < 3) return false;
  let sum = 0;
  for (let i = 0; i < state.recent.length; i++) sum += state.recent[i];
  state.zeroP = sum / state.recent.length;
  state.locked = false;
  state.arm = 0;
  state.live = false;
  return true;
}

/** 绝对方向四元数的仰角，单位度。正数是抬头。 */
export function anglesFromQuat(x, y, z, w) {
  const sinp = 2 * (w * x + y * z);
  const c = sinp > 1 ? 1 : (sinp < -1 ? -1 : sinp);
  return { pitch: Math.asin(c) * 180 / Math.PI };
}

/**
 * 喂一帧仰角。返回 1 下一页，-1 上一页，0 不动。
 * 正的仰角差是抬头。没校准、或正在记基准时，一律不翻。
 */
export function takeHead(state, angles) {
  if (!state || !angles) return 0;
  const pitch = angles.pitch;
  if (pitch == null || pitch !== pitch) return 0;
  if (state.arm > 0) {
    state.sum += pitch;
    state.n += 1;
    state.arm -= 1;
    if (state.arm === 0 && state.n) {
      state.zeroP = state.sum / state.n;
      state.fresh = true;
    }
    return 0;
  }
  if (state.zeroP == null || !state.live) return 0;
  const d = pitch - state.zeroP;
  if (state.locked) {
    if (d < state.back && d > -state.back) state.locked = false;
    return 0;
  }
  if (d >= state.up) {
    state.locked = true;
    return 1;
  }
  if (d <= -state.down) {
    state.locked = true;
    return -1;
  }
  return 0;
}
