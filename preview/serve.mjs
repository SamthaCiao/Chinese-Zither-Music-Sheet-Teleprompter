/**
 * 本机预览。谱图放在仓库的「谱子图片/曲名/」里，或从页面上传到这个目录。
 * 切出来的屏先放在 preview/out/review，不写进 aiui-agent。
 * 批准之后，才在 dist/aiui-agent 放一份可导入乐奇工作室的副本。
 * 不覆盖仓库根目录那份已经真机通过的 aix。
 *
 * 在 preview 目录执行：node serve.mjs
 */
import fs from 'fs';
import path from 'path';
import http from 'http';
import { spawn } from 'child_process';
import { fileURLToPath } from 'url';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, '..');
const scoreRoot = path.join(root, '谱子图片');
const catalogPath = path.join(root, 'scores', 'catalog.json');
const reviewDir = path.join(here, 'out', 'review');
const distDir = path.join(root, 'dist', 'aiui-agent');
const zipPath = path.join(root, 'dist', '古筝演奏琴谱提词器-待导入.zip');
const port = Number(process.env.PORT || 4877);

function safeName(name) {
  const base = path.basename(String(name || '')).replace(/[^\w.\u4e00-\u9fff-]+/g, '_');
  if (!base || base === '.' || base === '..') return '';
  return base;
}

function idOf(title) {
  const s = String(title || '').trim();
  if (/^[a-z0-9-]{1,40}$/i.test(s)) return s.toLowerCase();
  let h = 2166136261;
  for (let i = 0; i < s.length; i++) {
    h ^= s.charCodeAt(i);
    h = Math.imul(h, 16777619);
  }
  return 's' + (h >>> 0).toString(16);
}

function readCatalog() {
  if (!fs.existsSync(catalogPath)) return { songs: [] };
  return JSON.parse(fs.readFileSync(catalogPath, 'utf8'));
}

function writeCatalog(songs) {
  fs.mkdirSync(path.dirname(catalogPath), { recursive: true });
  fs.writeFileSync(catalogPath, JSON.stringify({ songs }, null, 2));
}

function songsFromDisk() {
  const prev = readCatalog();
  const kept = new Map((prev.songs || []).map((s) => [s.title, s]));
  const songs = [];
  if (!fs.existsSync(scoreRoot)) return songs;
  for (const name of fs.readdirSync(scoreRoot)) {
    const dir = path.join(scoreRoot, name);
    if (!fs.statSync(dir).isDirectory()) continue;
    const files = fs.readdirSync(dir).filter((f) => /\.jpe?g$/i.test(f)).sort();
    if (!files.length) continue;
    const old = kept.get(name) || {};
    songs.push({
      ...old,
      id: old.id || idOf(name),
      title: name,
      key: old.key || 'D',
      files: files.map((f) => '谱子图片/' + name + '/' + f)
    });
  }
  writeCatalog(songs);
  return songs;
}

function screensOf(song) {
  const out = { '2': [], '3': [] };
  for (const lines of ['2', '3']) {
    const dir = path.join(reviewDir, 'assets', song.id, 'L' + lines);
    if (!fs.existsSync(dir)) continue;
    out[lines] = fs.readdirSync(dir).filter((f) => f.endsWith('.jpg')).sort()
      .map((f) => '/review/' + song.id + '/L' + lines + '/' + f);
  }
  return out;
}

function runBake() {
  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, ['bake-screens.mjs'], {
      cwd: here,
      env: { ...process.env, REVIEW_DIR: reviewDir },
      windowsHide: true
    });
    let log = '';
    child.stdout.on('data', (b) => { log += b; });
    child.stderr.on('data', (b) => { log += b; });
    child.on('error', reject);
    child.on('close', (code) => {
      if (code) reject(new Error(log || ('切谱退出 ' + code)));
      else resolve(log);
    });
  });
}

function copyDir(src, dst) {
  fs.mkdirSync(dst, { recursive: true });
  for (const ent of fs.readdirSync(src, { withFileTypes: true })) {
    if (ent.name === 'node_modules') continue;
    const from = path.join(src, ent.name);
    const to = path.join(dst, ent.name);
    if (ent.isDirectory()) copyDir(from, to);
    else fs.copyFileSync(from, to);
  }
}

function crc32(buf) {
  let c = -1;
  for (let i = 0; i < buf.length; i++) {
    c ^= buf[i];
    for (let k = 0; k < 8; k++) c = (c >>> 1) ^ (0xedb88320 & -(c & 1));
  }
  return (~c) >>> 0;
}

function u16(n) { const b = Buffer.alloc(2); b.writeUInt16LE(n); return b; }
function u32(n) { const b = Buffer.alloc(4); b.writeUInt32LE(n >>> 0); return b; }

function zipDir(dir, dest) {
  const files = [];
  function walk(rel) {
    const abs = path.join(dir, rel);
    for (const ent of fs.readdirSync(abs, { withFileTypes: true })) {
      const next = rel ? rel + '/' + ent.name : ent.name;
      if (ent.isDirectory()) walk(next);
      else files.push(next.split(path.sep).join('/'));
    }
  }
  walk('');
  const parts = [];
  const central = [];
  let offset = 0;
  for (const name of files) {
    const data = fs.readFileSync(path.join(dir, name));
    const nameBuf = Buffer.from(name);
    const crc = crc32(data);
    const local = Buffer.concat([
      u32(0x04034b50), u16(20), u16(0), u16(0), u16(0), u16(0),
      u32(crc), u32(data.length), u32(data.length), u16(nameBuf.length), u16(0),
      nameBuf, data
    ]);
    parts.push(local);
    central.push(Buffer.concat([
      u32(0x02014b50), u16(20), u16(20), u16(0), u16(0), u16(0), u16(0),
      u32(crc), u32(data.length), u32(data.length), u16(nameBuf.length), u16(0), u16(0),
      u16(0), u16(0), u32(0), u32(offset), nameBuf
    ]));
    offset += local.length;
  }
  const centralBuf = Buffer.concat(central);
  const end = Buffer.concat([
    u32(0x06054b50), u16(0), u16(0), u16(files.length), u16(files.length),
    u32(centralBuf.length), u32(offset), u16(0)
  ]);
  fs.mkdirSync(path.dirname(dest), { recursive: true });
  fs.writeFileSync(dest, Buffer.concat(parts.concat([centralBuf, end])));
}

function approve() {
  const songsFile = path.join(reviewDir, 'songs.js');
  const assets = path.join(reviewDir, 'assets');
  if (!fs.existsSync(songsFile) || !fs.existsSync(assets)) {
    throw new Error('还没有切好的屏。先看一遍，再批准。');
  }
  fs.rmSync(distDir, { recursive: true, force: true });
  copyDir(path.join(root, 'aiui-agent'), distDir);
  copyDir(assets, path.join(distDir, 'assets'));
  fs.copyFileSync(songsFile, path.join(distDir, 'songs.js'));
  zipDir(distDir, zipPath);
  return { dir: distDir, zip: zipPath };
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    req.on('data', (c) => chunks.push(c));
    req.on('end', () => resolve(Buffer.concat(chunks)));
    req.on('error', reject);
  });
}

function send(res, code, body, type) {
  const buf = Buffer.isBuffer(body) ? body : Buffer.from(body);
  res.writeHead(code, {
    'Content-Type': type || 'application/json; charset=utf-8',
    'Content-Length': buf.length,
    'Cache-Control': 'no-store'
  });
  res.end(buf);
}

function parseMultipart(req, body) {
  const ctype = req.headers['content-type'] || '';
  const m = ctype.match(/boundary=(?:"([^"]+)"|([^;]+))/i);
  if (!m) return null;
  const boundary = Buffer.from('--' + (m[1] || m[2]));
  const parts = [];
  let start = body.indexOf(boundary) + boundary.length;
  while (start < body.length) {
    if (body[start] === 45 && body[start + 1] === 45) break;
    if (body[start] === 13) start += 2;
    const headEnd = body.indexOf('\r\n\r\n', start);
    if (headEnd < 0) break;
    const head = body.slice(start, headEnd).toString('utf8');
    const dataStart = headEnd + 4;
    const next = body.indexOf(boundary, dataStart);
    if (next < 0) break;
    let dataEnd = next - 2;
    if (body[dataEnd] !== 13) dataEnd = next;
    const name = (head.match(/name="([^"]+)"/) || [])[1] || '';
    const filename = (head.match(/filename="([^"]*)"/) || [])[1] || '';
    parts.push({ name, filename, data: body.slice(dataStart, dataEnd) });
    start = next + boundary.length;
  }
  return parts;
}

const server = http.createServer(async (req, res) => {
  try {
    const url = new URL(req.url, 'http://127.0.0.1');
    if (req.method === 'GET' && (url.pathname === '/' || url.pathname === '/index.html')) {
      return send(res, 200, fs.readFileSync(path.join(here, 'index.html')), 'text/html; charset=utf-8');
    }
    if (req.method === 'GET' && url.pathname === '/api/songs') {
      const songs = songsFromDisk().map((s) => ({ ...s, screens: screensOf(s) }));
      return send(res, 200, JSON.stringify({ songs, scoreRoot }));
    }
    if (req.method === 'POST' && url.pathname === '/api/upload') {
      const body = await readBody(req);
      const parts = parseMultipart(req, body) || [];
      const title = ((parts.find((p) => p.name === 'title') || {}).data || Buffer.from('')).toString('utf8').trim();
      const key = ((parts.find((p) => p.name === 'key') || {}).data || Buffer.from('D')).toString('utf8').trim() || 'D';
      const folder = safeName(title);
      if (!folder) return send(res, 400, JSON.stringify({ error: '先写曲名' }));
      const dir = path.join(scoreRoot, folder);
      fs.mkdirSync(dir, { recursive: true });
      let n = 0;
      for (const part of parts) {
        if (part.name !== 'files' || !part.data.length) continue;
        n += 1;
        const file = String(n).padStart(2, '0') + '.jpg';
        fs.writeFileSync(path.join(dir, file), part.data);
      }
      if (!n) return send(res, 400, JSON.stringify({ error: '没有图' }));
      const songs = songsFromDisk();
      const song = songs.find((s) => s.title === folder);
      if (song) song.key = key.toUpperCase();
      writeCatalog(songs);
      return send(res, 200, JSON.stringify({ ok: true, title: folder }));
    }
    if (req.method === 'POST' && url.pathname === '/api/render') {
      songsFromDisk();
      const songs = readCatalog().songs || [];
      if (!songs.length) return send(res, 400, JSON.stringify({ error: '谱子图片里还没有曲目' }));
      fs.mkdirSync(reviewDir, { recursive: true });
      const log = await runBake();
      return send(res, 200, JSON.stringify({
        ok: true,
        log,
        songs: songs.map((s) => ({ ...s, screens: screensOf(s) }))
      }));
    }
    if (req.method === 'POST' && url.pathname === '/api/approve') {
      const made = approve();
      return send(res, 200, JSON.stringify({
        ok: true,
        dir: path.relative(root, made.dir),
        zip: path.relative(root, made.zip)
      }));
    }
    if (req.method === 'GET' && url.pathname.startsWith('/review/')) {
      const rel = decodeURIComponent(url.pathname.slice('/review/'.length));
      const file = path.normalize(path.join(reviewDir, 'assets', rel));
      if (!file.startsWith(path.join(reviewDir, 'assets'))) return send(res, 403, 'no');
      if (!fs.existsSync(file)) return send(res, 404, 'no');
      return send(res, 200, fs.readFileSync(file), 'image/jpeg');
    }
    send(res, 404, JSON.stringify({ error: '没有这个地址' }));
  } catch (err) {
    send(res, 500, JSON.stringify({ error: err && err.message ? err.message : String(err) }));
  }
});

server.listen(port, '127.0.0.1', () => {
  console.log('预览 http://127.0.0.1:' + port);
});
