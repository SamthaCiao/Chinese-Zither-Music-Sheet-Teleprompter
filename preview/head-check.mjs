import { createHeadTurn, anglesFromQuat, takeHead, noteHead, commitHead } from '../aiui-agent/head-turn.js';
import { pcmToFloat, sampleRateOf, createLevel, levelFrame } from '../aiui-agent/pcm-frame.js';

function qx(deg) {
  const a = deg * Math.PI / 360;
  return [Math.sin(a), 0, 0, Math.cos(a)];
}

function feed(state, pitch) {
  return takeHead(state, { pitch: pitch });
}

function zeroAt(state, pitch) {
  for (let i = 0; i < 4; i++) noteHead(state, { pitch: pitch });
  if (!commitHead(state)) fail('基准没记下');
  if (feed(state, pitch + 40) !== 0) fail('没点开始演奏不该翻');
  state.live = true;
}

const early = createHeadTurn();
noteHead(early, { pitch: 1 });
noteHead(early, { pitch: 1 });
if (commitHead(early)) fail('读数不够不该记下基准');

const bare = createHeadTurn();
if (feed(bare, 40) !== 0) fail('没校准不该翻');
if (feed(bare, -40) !== 0) fail('没校准低头也不该翻');

const head = createHeadTurn();
zeroAt(head, -12);
if (feed(head, -4) !== 0) fail('没到平视不该翻');
if (feed(head, 4) !== 1) fail('平视该下一页');
if (feed(head, 20) !== 0) fail('停在平视不该连翻');
if (feed(head, -12) !== 0) fail('回到看琴弦只是解锁');
if (feed(head, -30) !== -1) fail('再低头该上一页');
if (feed(head, -14) !== 0) fail('看琴附近的小幅不该翻');

const small = createHeadTurn();
zeroAt(small, 0);
if (feed(small, 8) !== 0) fail('没抬到平视不该翻');
if (feed(small, -10) !== 0) fail('没低过看琴弦一档不该翻');

const looked = anglesFromQuat.apply(null, qx(20));
if (Math.abs(looked.pitch - 20) > 0.2) fail('抬头角 ' + looked.pitch);

const i16 = new Int16Array(64);
for (let i = 0; i < i16.length; i++) i16[i] = Math.round(16384 * Math.sin(i / 3));
const fromInt = pcmToFloat(i16);
if (Math.abs(fromInt[1] - i16[1] / 32768) > 0.02) fail('整数采样');
const f32 = new Float32Array(64);
for (let i = 0; i < f32.length; i++) f32[i] = 0.25 * Math.sin(i / 3);
const fromFloat = pcmToFloat(f32);
if (Math.abs(fromFloat[1] - f32[1]) > 0.02) fail('浮点采样 ' + fromFloat[1]);
if (sampleRateOf(640, 40) !== 16000) fail('16k');
if (sampleRateOf(1920, 40) !== 48000) fail('48k');

const level = createLevel();
const quiet = new Float32Array(320);
for (let i = 0; i < quiet.length; i++) quiet[i] = 0.02 * Math.sin(i / 8);
const lifted = levelFrame(level, quiet);
let peak = 0;
for (let i = 0; i < lifted.length; i++) peak = Math.max(peak, Math.abs(lifted[i]));
if (peak < 0.1) fail('轻声该抬起来 ' + peak);
const hush = createLevel();
const silent = new Float32Array(320);
silent[0] = 0.0002;
const stayed = levelFrame(hush, silent);
if (Math.abs(stayed[0]) > 0.002) fail('静音不该放大');

console.log('头控和采样都过了');

function fail(msg) {
  console.error(msg);
  process.exit(1);
}
