#!/usr/bin/env node
// Records the README animations from the demo on the website (website/index.html) and writes animated WebP
// files to docs/readme/<en|zh>/:
//   capture.webp     stage scene 1: frame a word in a video's subtitles, the panel explains it
//   point.webp       stage scene 2: rest the pointer on a word in an article, press a key, save it
//
//   node scripts/readme-assets.mjs                  # both languages, website/ served locally
//   node scripts/readme-assets.mjs --lang en        # one language
//   node scripts/readme-assets.mjs --only capture   # one animation (capture or point)
//   node scripts/readme-assets.mjs --site https://getnewword.us-cloud.uk
//   node scripts/readme-assets.mjs --format gif     # GIF instead of WebP
//
// Needs: Google Chrome, Playwright (global install at /opt/homebrew/lib/node_modules/playwright, or
// PLAYWRIGHT_DIR), and `img2webp` + ImageMagick (`brew install webp imagemagick`).
// Frames are 2x screenshots of the stage taken in a loop (about 20 a second). The page around the stage is
// transparent, so only its rounded corners are see-through and one file suits GitHub's light and dark themes.
// Files are 1680 px wide, to be shown at 840.

import { createRequire } from 'node:module';
import http from 'node:http';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const require = createRequire(import.meta.url);
const { chromium } = require(process.env.PLAYWRIGHT_DIR || '/opt/homebrew/lib/node_modules/playwright');

const arg = (name, def) => { const i = process.argv.indexOf('--' + name); return i > 0 ? process.argv[i + 1] : def; };
const langs = arg('lang', 'en,zh').split(',');
const only = arg('only', 'capture,point').split(',');
const format = arg('format', 'webp');
const scale = 2;
const width = 1680;
const minGap = 45;   // ms between kept frames (about 20 a second)
const maxKB = 2500;

function serveWebsite() {
  const dir = path.join(root, 'website');
  const types = { '.html': 'text/html; charset=utf-8', '.json': 'application/json', '.png': 'image/png', '.js': 'text/javascript', '.css': 'text/css', '.svg': 'image/svg+xml' };
  const server = http.createServer((req, res) => {
    let p = decodeURIComponent(new URL(req.url, 'http://x').pathname);
    if (p.endsWith('/')) p += 'index.html';
    const file = path.join(dir, p);
    if (!file.startsWith(dir) || !fs.existsSync(file) || fs.statSync(file).isDirectory()) { res.writeHead(404).end(); return; }
    res.writeHead(200, { 'content-type': types[path.extname(file)] || 'application/octet-stream' });
    fs.createReadStream(file).pipe(res);
  });
  return new Promise((resolve) => server.listen(0, '127.0.0.1', () => resolve({ server, url: `http://127.0.0.1:${server.address().port}` })));
}

// Hide the rest of the page and pin the stage at the top left, on a transparent page.
const ISOLATE = `html,body{background:transparent!important;overflow:hidden!important}
  body>*:not(main):not(svg){display:none!important} main.page:not(#p-home){display:none!important}
  #p-home>*:not(#how){display:none!important}
  #how{position:fixed!important;left:20px;top:20px;margin:0!important;padding:0!important;width:1080px!important;max-width:none!important}
  #tabs,#how .cap{display:none!important}`;

// The first two tabs of the stage. The README shows the Anki card as a real screenshot (anki-card.png, scripts/readme-shots.mjs).
const jobs = [{ name: 'capture', scene: 1 }, { name: 'point', scene: 2 }].filter((j) => only.includes(j.name));

async function record(browser, site, lang, job, tmp) {
  const ctx = await browser.newContext({ viewport: { width: 1120, height: 680 }, colorScheme: 'light', deviceScaleFactor: scale, reducedMotion: 'no-preference' });
  const page = await ctx.newPage();
  await page.goto(`${site}/?lang=${lang}`, { waitUntil: 'networkidle' });
  await page.addStyleTag({ content: ISOLATE });
  await page.evaluate(() => fitStage());
  await page.waitForTimeout(300);
  const box = await page.evaluate(() => { const r = document.querySelector('#stage').getBoundingClientRect(); return { x: Math.floor(r.left), y: Math.floor(r.top), w: Math.ceil(r.width), h: Math.ceil(r.height) }; });
  const cdp = await ctx.newCDPSession(page);
  await cdp.send('Emulation.setDefaultBackgroundColorOverride', { color: { r: 0, g: 0, b: 0, a: 0 } });
  const dir = path.join(tmp, `${lang}-${job.name}`);
  fs.mkdirSync(dir, { recursive: true });
  // scene(n) cross-fades from the scene that was showing; show it once, then restart it so the recording starts clean.
  await page.evaluate((n) => scene(n), job.scene);
  await page.waitForTimeout(700);
  const dur = await page.evaluate((n) => DUR[n], job.scene);
  const start = await page.evaluate((n) => { const t = Date.now(); scene(n); return t; }, job.scene);
  const end = start + dur - 80; // the next scene starts fading in at dur
  // Screenshots in a loop (about 50 ms each at 2x), each stamped with the middle of its capture.
  const frames = [];
  while (Date.now() < end) {
    const t0 = Date.now();
    const { data } = await cdp.send('Page.captureScreenshot', { format: 'png', clip: { x: box.x, y: box.y, width: box.w, height: box.h, scale }, optimizeForSpeed: true });
    const name = `f${String(frames.length).padStart(4, '0')}.png`;
    fs.writeFileSync(path.join(dir, name), Buffer.from(data, 'base64'));
    frames.push({ name, t: (t0 + Date.now()) / 2 });
  }
  await ctx.close();
  const kept = frames.filter((f) => f.t >= start && f.t <= end);
  if (!kept.length) throw new Error(`no frames recorded for ${lang} ${job.name}`);
  return { dir, frames: kept, end };
}

function encode(rec, out) {
  const { dir } = rec;
  // The screencast sends a frame only when the picture changes; the first kept frame stands for the start.
  const frames = [];
  for (const f of rec.frames) if (!frames.length || f.t - frames.at(-1).t >= minGap) frames.push(f);
  const small = path.join(dir, 'small');
  fs.mkdirSync(small, { recursive: true });
  for (const f of frames) {
    execFileSync('magick', [path.join(dir, f.name), '-resize', `${width}x`, '-strip', path.join(small, f.name)]);
  }
  const tail = Math.max(600, Math.round(rec.end - frames.at(-1).t));
  const durs = frames.map((f, i) => (i + 1 < frames.length ? Math.max(20, Math.round(frames[i + 1].t - f.t)) : tail));
  const seconds = Math.round(durs.reduce((a, b) => a + b, 0) / 100) / 10;
  for (const q of format === 'gif' ? [0] : [80, 72, 64, 56, 48]) {
    if (format === 'gif') {
      const list = [];
      frames.forEach((f, i) => list.push('-delay', String(Math.max(2, Math.round(durs[i] / 10))), path.join(small, f.name)));
      execFileSync('magick', ['-dispose', 'background', ...list, '-layers', 'OptimizePlus', '-loop', '0', out]);
    } else {
      const args = ['-loop', '0', '-lossy', '-q', String(q), '-m', '4'];
      frames.forEach((f, i) => args.push('-d', String(durs[i]), path.join(small, f.name)));
      execFileSync('img2webp', [...args, '-o', out]);
    }
    const kb = Math.round(fs.statSync(out).size / 1024);
    if (kb <= maxKB || format === 'gif') return { kb, q, frames: frames.length, seconds };
  }
  throw new Error(`${out} is still over ${maxKB} KB at the lowest quality`);
}

const { server, url } = arg('site') ? { server: null, url: arg('site').replace(/\/$/, '') } : await serveWebsite();
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'readme-assets-'));
const browser = await chromium.launch({ channel: 'chrome', headless: true });
try {
  for (const lang of langs) {
    const outDir = path.join(root, 'docs', 'readme', lang);
    fs.mkdirSync(outDir, { recursive: true });
    for (const job of jobs) {
      const rec = await record(browser, url, lang, job, tmp);
      const out = path.join(outDir, `${job.name}.${format}`);
      const info = encode(rec, out);
      console.log(`${path.relative(root, out)}: ${info.frames} frames, ${info.seconds} s, ${info.kb} KB${info.q ? ` (quality ${info.q})` : ''}`);
    }
  }
} finally {
  await browser.close();
  server?.close();
  if (!process.env.KEEP_FRAMES) fs.rmSync(tmp, { recursive: true, force: true }); else console.log('frames kept in', tmp);
}
