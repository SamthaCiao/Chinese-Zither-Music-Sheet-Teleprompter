/**
 * 核对「认谱 + 按边缘音翻页」。
 * 不过就退出码 1。结果写在 out/follow-check.json。
 *
 * 通过标准：
 * 1. 从 assets/score.png 读出的六行，等于练习谱上看得见的那 48 个音。
 * 2. 用这 48 个音合成拨弦（每行一小节）。匀速、较快、较慢三种，
 *    每一屏都在这一小节的最后一个音上翻到下一屏，不跳屏、不往回翻。
 * 3. 检出的音至少盖住 85% 的真音，音高误差不超过一个半音。
 */
import { execFileSync } from 'child_process';
import fs from 'fs';
import { createEar, pushSamples, wantNextScreen } from '../aiui-agent/follow-engine.js';
import { synthEvents } from './edge-phrase.mjs';

execFileSync('python', ['read-score.py'], { stdio: 'inherit' });
const score = JSON.parse(fs.readFileSync('out/score-notes.json', 'utf8'));
const EXPECT = ['12233445', '23344556', '34455667', '45566771', '56677112', '67711223'];
const DEG = { 1: 0, 2: 2, 3: 4, 4: 5, 5: 7, 6: 9, 7: 11 };

function midiOfDigit(ch) {
  return 62 + DEG[ch];
}

const readRows = score.rows.map((r) => r.notes);
const notesOk = readRows.length === EXPECT.length && readRows.every((r, i) => r === EXPECT[i]);
const screens = EXPECT.map((row) => row.split('').map(midiOfDigit));

function synth(events, sr) {
  return synthEvents(events, sr, 0.16);
}

function run(name, ioi) {
  const events = [];
  let t = 0.4;
  screens.forEach((row, s) => {
    row.forEach((midi, i) => {
      events.push({ t, midi, screen: s, index: s * 8 + i });
      t += ioi;
    });
  });
  const ear = createEar(16000);
  const pcm = synth(events, 16000);
  const turns = [];
  let screen = 0;
  const hop = 1600;
  for (let i = 0; i < pcm.length; i += hop) {
    pushSamples(ear, pcm.subarray(i, Math.min(pcm.length, i + hop)));
    if (wantNextScreen(ear, screens, screen)) {
      const last = ear.onsets[ear.onsets.length - 1];
      turns.push({ t: Number(last.t.toFixed(3)), to: screen + 2 });
      screen += 1;
    }
  }
  let covered = 0;
  for (const e of events) {
    const hit = ear.onsets.some((o) => Math.abs(o.t - e.t) < 0.22 && Math.abs(((o.midi % 12) + 12) % 12 - ((e.midi % 12) + 12) % 12) === 0);
    if (hit) covered++;
  }
  const problems = [];
  if (turns.length !== 5) problems.push('翻页次数 ' + turns.length + '，应是 5');
  turns.forEach((turn, k) => {
    const edge = events.find((e) => e.screen === k && e.index === k * 8 + 7);
    if (!edge) return;
    const dt = turn.t - edge.t;
    if (dt < -0.06 || dt > 0.2) problems.push('第 ' + (k + 2) + ' 屏晚/早了 ' + dt.toFixed(3) + 's');
    if (turn.to !== k + 2) problems.push('跳到了第 ' + turn.to + ' 屏');
  });
  for (let i = 1; i < turns.length; i++) {
    if (turns[i].to !== turns[i - 1].to + 1) problems.push('翻页没有一屏一屏走');
  }
  if (covered / events.length < 0.85) problems.push('音高盖住 ' + covered + '/' + events.length);
  return {
    name,
    ioi,
    onsets: ear.onsets.length,
    expected: events.length,
    covered: Number((covered / events.length).toFixed(2)),
    turns,
    pass: problems.length === 0,
    problems
  };
}

const cases = [run('匀速', 0.4), run('较快', 0.22), run('较慢', 0.7)];
const packedPlay = [screens.slice(0, 4).flat(), screens.slice(4).flat()];
const packed = [packedPlay[0].slice(-8), [60, 65, 70, 63]];
function runPacked(ioi) {
  const events = [];
  let t = 0.4;
  packedPlay.forEach((row) => {
    row.forEach((midi) => {
      events.push({ t, midi });
      t += ioi;
    });
  });
  const ear = createEar(16000);
  const pcm = synth(events, 16000);
  const turns = [];
  let screen = 0;
  for (let i = 0; i < pcm.length; i += 1600) {
    pushSamples(ear, pcm.subarray(i, Math.min(pcm.length, i + 1600)));
    if (wantNextScreen(ear, packed, screen)) {
      turns.push({ t: Number(ear.onsets[ear.onsets.length - 1].t.toFixed(3)), to: screen + 2 });
      screen += 1;
    }
  }
  const edgeT = 0.4 + 31 * ioi;
  const problems = [];
  if (turns.length !== 1) problems.push('两屏曲子应只翻 1 次，实际 ' + turns.length);
  else if (Math.abs(turns[0].t - edgeT) > 0.2) problems.push('翻页时刻 ' + turns[0].t + ' 离边缘音 ' + edgeT.toFixed(3));
  return { name: '眼镜上的两屏', ioi, turns, pass: problems.length === 0, problems };
}
cases.push(runPacked(0.4));
const report = {
  scoreRead: readRows,
  scorePass: notesOk,
  rule: '每一行是翻页前的那一小节。听完这一小节的最后一个音才翻，不看时钟。',
  cases,
  pass: notesOk && cases.every((c) => c.pass)
};
fs.mkdirSync('out', { recursive: true });
fs.writeFileSync('out/follow-check.json', JSON.stringify(report, null, 2));
console.log(JSON.stringify(report, null, 2));
if (!report.pass) process.exit(1);
