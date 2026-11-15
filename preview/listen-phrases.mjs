/**
 * 三首歌、每页 2 行和 3 行，都用谱上最后一小节的标准音来核对翻页。
 * 不读录音，不看时钟。不过就退出码 1。结果在 out/phrase-follow.json。
 *
 * 翻页条件：刚听完的音和这一小节一个不差。少一个音、中间多一个音、倒放、只弹头两个音，都不翻。停顿、回拖后再把这一小节弹完，才翻一次。
 */
import fs from 'fs';
import { synthEvents, hearPhrase } from './edge-phrase.mjs';

const songs = JSON.parse(fs.readFileSync('../aiui-agent/songs.js', 'utf8').replace(/^export default /, '').replace(/;\s*$/, ''));
const FOREIGN = [60, 65, 70, 63];

function synth(events, sr) {
  return synthEvents(events, sr);
}

function listen(events, phrases) {
  return hearPhrase(synth(events, 16000), phrases, 16000);
}

function breaker(phrase) {
  const avoid = phrase.length > 2 ? ((phrase[2] % 12) + 12) % 12 : -1;
  for (let m = 60; m < 84; m++) {
    const pc = ((m % 12) + 12) % 12;
    if (pc !== avoid) return m;
  }
  return 60;
}

function put(events, midis, state, opt) {
  const marks = [];
  const gap = (opt && opt.gap) || 0.28;
  midis.forEach((midi, i) => {
    events.push({
      t: state.t,
      midi,
      cents: opt && opt.cents ? (i % 2 ? 24 : -20) : 0,
      chord: !!(opt && opt.chord)
    });
    marks.push(state.t);
    state.t += gap;
    if (opt && opt.pauseAt && opt.pauseAt[i]) state.t += opt.pauseAt[i];
  });
  return marks;
}

function isSuffix(melody, phrase) {
  if (!phrase.length || phrase.length > melody.length) return false;
  for (let i = 0; i < phrase.length; i++) {
    if (melody[melody.length - phrase.length + i] !== phrase[i]) return false;
  }
  return true;
}

function build(body, phrase, pauses, withEnding) {
  const events = [];
  const state = { t: 0.25 };
  put(events, body, state, { gap: 0.26 });
  put(events, phrase.slice(0, 2), state, { gap: 0.26 });
  put(events, [breaker(phrase)], state, { gap: 0.26 });
  put(events, phrase.slice().reverse(), state, { gap: 0.26 });
  state.t += 0.55;
  const half = Math.max(2, Math.floor(phrase.length / 2));
  const partial = phrase.slice(0, half);
  put(events, partial, state, { gap: 0.26 });
  const partialEnd = state.t;
  state.t += pauses.scrub;
  let lastT = partialEnd;
  if (withEnding) {
    const pauseAt = {};
    pauseAt[0] = pauses.a;
    pauseAt[Math.min(phrase.length - 1, Math.floor(phrase.length / 2))] = pauses.b;
    const marks = put(events, phrase, state, { gap: 0.3, cents: true, chord: true, pauseAt });
    lastT = marks[marks.length - 1];
    state.t += 0.35;
    put(events, phrase, state, { gap: 0.26 });
  }
  return { events, lastT, partialEnd };
}

const problems = [];
const rows = [];

for (const song of songs) {
  for (const lines of ['2', '3']) {
    const layout = song.layouts[lines];
    if (!layout) {
      problems.push(song.title + ' 没有每页' + lines + '行');
      continue;
    }
    const phrases = layout.notes;
    const melodies = layout.melody || [];
    const probe = phrases[0] && phrases[0].length >= 2 ? phrases[0].slice(0, 2) : [62, 64];
    const gate = listen((() => {
      const events = [];
      const state = { t: 0.2 };
      put(events, probe, state, { gap: 0.3 });
      state.t += 3.2;
      return events;
    })(), [probe.concat([67, 69]), FOREIGN]);
    if (gate.length) problems.push(song.title + ' 每页' + lines + '行：只弹两个音再停 3 秒也翻了');

    for (let s = 0; s < phrases.length; s++) {
      const phrase = phrases[s];
      const melody = melodies[s] || [];
      const where = song.title + ' 每页' + lines + '行 第' + (s + 1) + '屏';
      if (s === phrases.length - 1) {
        const events = [];
        const state = { t: 0.2 };
        put(events, phrase, state, { gap: 0.28 });
        const turns = listen(events, [phrase]);
        if (turns.length) problems.push(where + ' 已经是最后一屏却翻了');
        rows.push({ where, notes: phrase.length, last: true, turns: turns.length });
        continue;
      }
      if (phrase.length < 4) {
        problems.push(where + ' 小节只有 ' + phrase.length + ' 个音');
        continue;
      }
      if (!isSuffix(melody, phrase)) problems.push(where + ' 小节不是这一屏旋律的结尾');
      const body = melody.slice(0, melody.length - phrase.length);
      const slow = { a: 0.4, b: 1.6, scrub: 0.5 };
      const fast = { a: 2.5, b: 0.3, scrub: 1.2 };
      const built = build(body, phrase, slow, true);
      const held = build(body, phrase, slow, false);
      const other = build(body, phrase, fast, true);
      const screens = [phrase, FOREIGN];
      const turns = listen(built.events, screens);
      const none = listen(held.events, screens);
      const turnsB = listen(other.events, screens);
      const near = (turn, at) => turn > at - 0.02 && turn < at + 0.4;
      if (none.length) problems.push(where + ' 没弹完小节就翻了');
      if (turns.length !== 1) problems.push(where + ' 应翻 1 次，实际 ' + turns.length);
      else if (!near(turns[0], built.lastT) || !(turns[0] > built.partialEnd)) problems.push(where + ' 翻页不在小节最后一个音，t=' + turns[0].toFixed(2));
      if (turnsB.length !== 1) problems.push(where + ' 换了停顿应翻 1 次，实际 ' + turnsB.length);
      else if (!near(turnsB[0], other.lastT)) problems.push(where + ' 长停顿后没有落在最后一个音');
      if (turns.length === 1 && turnsB.length === 1 && Math.abs(turns[0] - turnsB[0]) < 0.8) {
        problems.push(where + ' 两次停顿不一样，翻页时刻却几乎相同');
      }
      rows.push({
        where,
        notes: phrase.length,
        turns: turns.length,
        at: turns[0] ? Number(turns[0].toFixed(2)) : null,
        otherAt: turnsB[0] ? Number(turnsB[0].toFixed(2)) : null
      });
      console.log(where, '小节', phrase.length, '音', turns.length === 1 ? '过' : '不过');
    }
  }
}

const report = {
  rule: '翻页只认当前屏最后一小节的音级，末尾一串要逐个对上。标准音可以偏 20 音分，也可以带一个较轻的五度。少一个音、中间多一个音、倒放、只弹两个音，都不翻。不看时钟。回拖后再把这一小节弹完才翻。切屏处再弹一遍不连翻。',
  songs: songs.map((s) => s.title),
  rows,
  problems,
  pass: problems.length === 0
};
fs.mkdirSync('out', { recursive: true });
fs.writeFileSync('out/phrase-follow.json', JSON.stringify(report, null, 2));
console.log(problems.length ? problems.join('\n') : '三首歌的小节翻页都过了');
if (!report.pass) process.exit(1);
