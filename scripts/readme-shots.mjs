#!/usr/bin/env node
// Takes the README's screenshots of the real app and writes them to docs/readme/<en|zh>/:
//   lookup.png       the lookup panel next to a framed word on a page
//   main-light.png   the main window with the word book, light and dark
//   main-dark.png
//   anki-card.png    the back of the Anki card the app made (its section labels follow the interface language)
//
//   GNW_DEMO_KEY=<DeepSeek API key> node scripts/readme-shots.mjs        # both languages
//   GNW_DEMO_KEY=… node scripts/readme-shots.mjs --lang en --no-build
//
// How it works: it builds a Debug copy named GetNewWord with its own bundle id (com.getnewword.app.readme.dev:
// its own data folder, settings and Anki deck, nothing shared with GetNewWord or GetNewWord Dev), renders the demo
// pages below in Chrome as full-screen images, and starts the copy with GNW_DEMO (GetNewWord/Utilities/DemoMode.swift).
// The copy then frames the marked words on those images one after another, as if you had dragged a box over them;
// local OCR, the DeepSeek request, the panel, saving, pronunciation and the Anki sync are the normal code. A
// throwaway Anki profile (its own base folder, AnkiConnect copied from your Anki) receives the cards, so your own
// Anki must be closed. Windows are captured one by one with `screencapture -l`: nothing else on the screen is
// recorded, the screen may be locked, and the app is started from this shell so it uses the terminal's screen
// recording permission. At the end the copy's data folder and settings and the Anki profile are deleted.
//
// Needs: Xcode and XcodeGen, Google Chrome, Playwright (global install at /opt/homebrew/lib/node_modules/playwright,
// or PLAYWRIGHT_DIR), ImageMagick, Anki with AnkiConnect (add-on 2055492159), python3.

import { createRequire } from 'node:module';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync, spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const require = createRequire(import.meta.url);
const { chromium } = require(process.env.PLAYWRIGHT_DIR || '/opt/homebrew/lib/node_modules/playwright');

const arg = (name, def) => { const i = process.argv.indexOf('--' + name); return i > 0 ? process.argv[i + 1] : def; };
const langs = arg('lang', 'zh,en').split(',');
const key = process.env.GNW_DEMO_KEY;
if (!key) { console.error('Set GNW_DEMO_KEY to a DeepSeek API key: the copy uses it for the lookups and never stores it.'); process.exit(1); }

const bundleId = 'com.getnewword.app.readme.dev';
const app = path.join(root, 'build/Readme/Build/Products/Debug/GetNewWord.app');
const home = os.homedir();
const dataDir = path.join(home, 'Library/Application Support', `GetNewWord Dev (${bundleId})`);
const ankiApp = '/Applications/Anki.app/Contents/MacOS/Anki';
const ankiConnect = path.join(home, 'Library/Application Support/Anki2/addons21/2055492159');
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// ---------- Demo pages: words to frame are marked data-w="<order>" ----------

const PAGE_CSS = `html,body{margin:0;height:100%;overflow:hidden}
  body{background:#f7f6f2;color:#1d1d1f;font-family:Georgia,"Times New Roman",serif;-webkit-font-smoothing:antialiased}
  .bar{height:54px;display:flex;align-items:center;gap:12px;padding:0 44px;border-bottom:1px solid #e3e0d6;background:#fcfbf8;font:600 15px -apple-system,system-ui}
  .logo{width:22px;height:22px;border-radius:6px;background:#2f6f5e}
  .nav{display:flex;gap:24px;margin-left:30px;font-weight:500;color:#6e6e73}
  .sp{flex:1} .sub{font-weight:500;color:#2f6f5e}
  main{width:720px;margin:0 auto;padding:52px 0 0}
  .kick{font:700 12px -apple-system,system-ui;letter-spacing:.14em;text-transform:uppercase;color:#2f6f5e}
  h1{font-size:40px;line-height:1.15;margin:12px 0 12px;font-weight:700}
  .dek{font-size:21px;line-height:1.45;color:#55555a;margin:0 0 14px}
  .by{font:13px -apple-system,system-ui;color:#8e8e93;margin:0 0 30px}
  p{font-size:20px;line-height:1.65;margin:0 0 20px}`;

const VIDEO_CSS = `html,body{margin:0;height:100%;overflow:hidden;background:#0b0c10;font-family:-apple-system,system-ui}
  .scene{position:absolute;inset:0;background:linear-gradient(180deg,#2b3550 0%,#5b5f7d 46%,#c8907a 64%,#2a2f3a 64.2%,#1c2029 100%)}
  .sun{position:absolute;left:58%;top:52%;width:130px;height:130px;border-radius:50%;background:#f3c38f;opacity:.8}
  .hill{position:absolute;bottom:36%;border-radius:50% 50% 0 0;background:#3a3f55}
  .road{position:absolute;left:50%;bottom:0;width:0;height:0;transform:translateX(-50%);border-left:260px solid transparent;border-right:260px solid transparent;border-bottom:350px solid #2e333f}
  .bike{position:absolute;left:46%;bottom:31%;width:110px;height:50px}
  .bike i{position:absolute;bottom:0;width:40px;height:40px;border:4px solid #0f1117;border-radius:50%}
  .bike i:first-child{left:0} .bike i:last-child{right:0}
  .subs{position:absolute;left:0;right:0;bottom:118px;text-align:center}
  .subs span.line{display:inline-block;padding:6px 16px;background:rgba(0,0,0,.72);color:#fff;font-size:34px;line-height:1.3;border-radius:6px}
  .ctrl{position:absolute;left:0;right:0;bottom:0;height:76px;display:flex;align-items:center;gap:18px;padding:0 36px;background:linear-gradient(0deg,rgba(0,0,0,.75),transparent);color:#e6e6ea;font-size:15px;font-variant-numeric:tabular-nums}
  .ctrl .bar{flex:1;height:5px;border-radius:3px;background:rgba(255,255,255,.25)} .ctrl .bar i{display:block;width:31%;height:100%;border-radius:3px;background:#e5484d}
  .ctrl .pp{width:0;height:0;border-top:10px solid transparent;border-bottom:10px solid transparent;border-left:16px solid #fff}
  .title{position:absolute;left:36px;top:30px;color:rgba(255,255,255,.85);font-size:17px;font-weight:600}`;

const article = (t) => `<!doctype html><meta charset="utf-8"><style>${PAGE_CSS}</style>
  <div class="bar"><span class="logo"></span>Field Notes<span class="nav">${t.nav.map((n) => `<span>${n}</span>`).join('')}</span><span class="sp"></span><span class="sub">${t.subscribe}</span></div>
  <main><div class="kick">${t.kicker}</div><h1>${t.title}</h1><p class="dek">${t.dek}</p><div class="by">${t.by}</div>${t.paragraphs.map((p) => `<p>${p}</p>`).join('')}</main>`;

const video = (t) => `<!doctype html><meta charset="utf-8"><style>${VIDEO_CSS}</style>
  <div class="scene"><div class="sun"></div><div class="hill" style="left:-8%;width:46%;height:210px"></div><div class="hill" style="left:52%;width:60%;height:160px;background:#343a4e"></div>
  <div class="road"></div><div class="bike"><i></i><i></i></div></div>
  <div class="title">${t.title}</div>
  <div class="subs"><span class="line">${t.subtitle}</span></div>
  <div class="ctrl"><span class="pp"></span><span>${t.time}</span><span class="bar"><i></i></span><span>${t.length}</span></div>`;

// The German video both languages use; the app has German and English categories built in, other languages stay uncategorized.
const GERMAN_VIDEO = video({ title: 'Lieferketten im Wandel', time: '03:12', length: '10:48',
  subtitle: 'Die <span data-w="1">Nachhaltigkeit</span> der Lieferketten hat deutlich zugenommen.' });

const LANGS = {
  // Chinese readers: an English article and a German video; explanations in Chinese.
  zh: {
    ui: 'zh-Hans', target: 'zh-Hans', panel: 2, card: true,
    pages: [
      GERMAN_VIDEO,
      article({ nav: ['Cities', 'Climate', 'Work', 'Archive'], subscribe: 'Subscribe', kicker: 'Cities',
        title: 'Why cities are quietly making room for bikes',
        dek: 'Pop-up lanes were meant to last a summer. Many of them are still there.',
        by: 'Field Notes · 6 min read',
        paragraphs: [
          'For decades, the car was the default answer to every transport question. That assumption is now being <span data-w="6">revisited</span>. In Paris, Seville and Bogotá, bike lanes built in a hurry have proved remarkably <span data-w="7">resilient</span>: once people use them, taking them away becomes politically <span data-w="5">untenable</span>.',
          'Planners are careful not to overstate the case. Cycling will not replace buses or trains, and winter weather remains a real <span data-w="3">deterrent</span>. But the evidence that safe, connected lanes <span data-w="4">pay off</span> is hard to ignore.',
          'What changed is less the technology than the mood. Bikes used to be a weekend hobby; now they are <span data-w="2">ubiquitous</span> at rush hour, and shops that once fought the lanes have learned to live with them.',
        ] }),
    ],
  },
  // English readers: a German article and the German video; explanations in English.
  en: {
    ui: 'en', target: 'en', panel: 4, card: true,
    pages: [
      GERMAN_VIDEO,
      article({ nav: ['Städte', 'Klima', 'Arbeit', 'Archiv'], subscribe: 'Abonnieren', kicker: 'Städte',
        title: 'Warum Städte leise Platz für Fahrräder schaffen',
        dek: 'Die Pop-up-Radwege sollten einen Sommer halten. Viele gibt es heute noch.',
        by: 'Field Notes · 6 Min. Lesezeit',
        paragraphs: [
          'Jahrzehntelang war das Auto die selbstverständliche Antwort auf jede Verkehrsfrage. Diese Annahme wird inzwischen <span data-w="6">hinterfragt</span>. In Paris, Sevilla und Bogotá haben sich hastig gebaute Radwege als erstaunlich <span data-w="7">beständig</span> erwiesen: Wer sie einmal benutzt, will sie nicht mehr hergeben.',
          'Planer warnen davor, die Wirkung zu <span data-w="5">überschätzen</span>. Das Fahrrad ersetzt weder Bus noch Bahn, und im Winter bleibt das Wetter eine echte <span data-w="3">Hürde</span>. Dass sich sichere, durchgehende Wege <span data-w="4">lohnen</span>, lässt sich aber kaum bestreiten.',
          'Geändert hat sich weniger die Technik als die Stimmung. Nach <span data-w="2">Feierabend</span> sind die Radwege heute voller als die Straßen, und Läden, die früher dagegen waren, haben sich damit abgefunden.',
        ] }),
    ],
  },
};

// ---------- Helpers ----------

function screenSize() {
  const out = execFileSync('osascript', ['-l', 'JavaScript', '-e',
    'ObjC.import("AppKit"); const s = $.NSScreen.mainScreen; JSON.stringify({ w: s.frame.size.width, h: s.frame.size.height, scale: s.backingScaleFactor })']);
  return JSON.parse(out);
}

/** On-screen windows of one process: [{ id, layer, x, y, w, h }] in points, top-left origin */
function windowsOf(pid) {
  const out = execFileSync('osascript', ['-l', 'JavaScript', '-e',
    `ObjC.import("CoreGraphics"); const l = ObjC.deepUnwrap(ObjC.castRefToObject($.CGWindowListCopyWindowInfo($.kCGWindowListOptionOnScreenOnly, $.kCGNullWindowID)));
     JSON.stringify(l.filter((w) => w.kCGWindowOwnerPID === ${pid}).map((w) => ({ id: w.kCGWindowNumber, layer: w.kCGWindowLayer, x: w.kCGWindowBounds.X, y: w.kCGWindowBounds.Y, w: w.kCGWindowBounds.Width, h: w.kCGWindowBounds.Height })))`]);
  return JSON.parse(out);
}

async function waitFor(what, test, timeoutMs) {
  const until = Date.now() + timeoutMs;
  for (;;) {
    const v = test();
    if (v) return v;
    if (Date.now() > until) throw new Error(`timed out waiting for ${what}`);
    await sleep(500);
  }
}

const appLog = () => { try { return fs.readFileSync(path.join(dataDir, 'app.log'), 'utf8'); } catch { return ''; } };

function defaults(...args) { execFileSync('defaults', [args[0], bundleId, ...args.slice(1)]); }

function resetCopy() {
  fs.rmSync(dataDir, { recursive: true, force: true });
  try { execFileSync('defaults', ['delete', bundleId], { stdio: 'ignore' }); } catch { /* no settings yet */ }
  for (const p of [`Preferences/${bundleId}.plist`, `Caches/${bundleId}`, `HTTPStorages/${bundleId}`, `HTTPStorages/${bundleId}.binarycookies`,
    `WebKit/${bundleId}`, `Saved Application State/${bundleId}.savedState`]) {
    fs.rmSync(path.join(home, 'Library', p), { recursive: true, force: true });
  }
}

function launch(env, log) {
  const fd = fs.openSync(log, 'a');
  const child = spawn(path.join(app, 'Contents/MacOS/GetNewWord'), [], { env: { ...process.env, ...env }, stdio: ['ignore', fd, fd] });
  child.on('exit', (code, signal) => { if (code !== null && code !== 0) console.error(`GetNewWord exited with ${code} (log: ${log})`); });
  return child;
}

async function quit(child) {
  if (child.exitCode !== null || child.signalCode) return;
  child.kill('SIGTERM');
  await new Promise((r) => child.once('exit', r));
}

function capture(windowId, out) { execFileSync('screencapture', ['-x', '-l', String(windowId), out]); }

async function mainWindow(child) {
  return waitFor('the main window', () => {
    if (child.exitCode !== null) throw new Error('GetNewWord quit before its main window opened');
    return windowsOf(child.pid).find((w) => w.layer === 0 && w.w >= 900);
  }, 30000);
}

// ---------- Anki: a throwaway profile that only AnkiConnect talks to ----------

async function anki(action, params = {}) {
  const res = await fetch('http://127.0.0.1:8765', { method: 'POST', body: JSON.stringify({ action, version: 6, params }), signal: AbortSignal.timeout(10000) });
  const { result, error } = await res.json();
  if (error) throw new Error(`AnkiConnect ${action}: ${error}`);
  return result;
}

async function startAnki(base, log) {
  if (await anki('version').then(() => true, () => false)) throw new Error('Anki is already running: quit it first, the cards must not go into your own collection.');
  if (!fs.existsSync(path.join(ankiConnect, '__init__.py'))) throw new Error(`AnkiConnect not found at ${ankiConnect}`);
  const addon = path.join(base, 'addons21/2055492159');
  fs.mkdirSync(addon, { recursive: true });
  for (const f of fs.readdirSync(ankiConnect)) if (f.endsWith('.py') || f === 'config.json' || f === 'manifest.json') fs.copyFileSync(path.join(ankiConnect, f), path.join(addon, f));
  // A newer "mod" than AnkiWeb's, so Anki does not offer to update the add-on.
  fs.writeFileSync(path.join(addon, 'meta.json'), JSON.stringify({ mod: Math.floor(Date.now() / 1000), disabled: false }));
  // Profile "Demo" with the first-run language question already answered, no sync, no update checks.
  execFileSync('python3', ['-I', '-c', `import sqlite3, pickle, time, random, sys
c = sqlite3.connect(sys.argv[1]); now = int(time.time())
c.execute("create table profiles (name text primary key collate nocase, data blob not null)")
meta = dict(ver=0, updates=False, created=now, id=random.randrange(0, 2**63), lastMsg=-1, suppressUpdate=True, firstRun=False, defaultLang="en_US", last_loaded_profile_name="Demo")
prof = dict(mainWindowGeom=None, mainWindowState=None, numBackups=0, lastOptimize=now, searchHistory=[], lastTextColor="#00f", lastHighlightColor="#ff0", syncKey=None, syncMedia=False, autoSync=False, allowHTML=False, importMode=1, lastColour="#00f", stripHTML=True, deleteMedia=False)
c.execute("insert into profiles values (?, ?)", ("_global", pickle.dumps(meta)))
c.execute("insert into profiles values (?, ?)", ("Demo", pickle.dumps(prof)))
c.commit()`, path.join(base, 'prefs21.db')]);
  const fd = fs.openSync(log, 'a');
  const child = spawn(ankiApp, ['--base', base, '--profile', 'Demo', '--lang', 'en'], { stdio: ['ignore', fd, fd] });
  const until = Date.now() + 60000;
  while (!(await anki('version').then(() => true, () => false))) {
    if (child.exitCode !== null || Date.now() > until) throw new Error(`AnkiConnect did not come up (log: ${log})`);
    await sleep(500);
  }
  return child;
}

// Anki ignores SIGTERM; ask it to quit, and only kill it if it is still there after 15 s (the profile is thrown away).
async function stopAnki(child) {
  if (child.exitCode !== null || child.signalCode) return;
  await anki('guiExitAnki').catch(() => {});
  const exited = new Promise((r) => child.once('exit', r));
  if (!(await Promise.race([exited.then(() => true), sleep(15000).then(() => false)]))) { child.kill('SIGKILL'); await exited; }
}

const REPLAY = '<a class="replay-button soundLink"><svg class="playImage" viewBox="0 0 64 64"><circle cx="32" cy="32" r="29"/><path d="M56.502,32.301l-37.502,20.101l0.329,-40.804l37.173,20.703Z"/></svg></a>';
// What Anki's reviewer puts around a card (its body margin, image size limit and replay button).
const REVIEWER_CSS = `body{margin:20px;overflow-wrap:break-word} img{max-width:100%}
  .replay-button{display:inline-block;vertical-align:middle} .replay-button svg{width:40px;height:40px}
  .replay-button svg circle{fill:#fff;stroke:#414141} .replay-button svg path{fill:#414141}`;

/** The back of the card for `word`: the HTML Anki rendered for it (cardsInfo), drawn in Chrome at reviewer width.
 *  Anki's own window stays blank while the screen is locked, so it cannot be captured directly. */
async function renderCard(browser, base, word, out) {
  const [cardId] = await anki('findCards', { query: `"Front:${word}"` });
  if (!cardId) throw new Error(`no Anki card for ${word}`);
  const [card] = await anki('cardsInfo', { cards: [cardId] });
  const media = path.join(base, 'Demo/collection.media');
  const html = `<!doctype html><meta charset="utf-8"><base href="file://${media}/"><style>${REVIEWER_CSS}${card.css}</style>
    <body class="card card1 isMac"><div id="qa">${card.answer.replace(/\[anki:play:[qa]:\d+\]/g, REPLAY)}</div></body>`;
  const file = path.join(path.dirname(out), 'card.html');
  fs.writeFileSync(file, html);
  const page = await browser.newPage({ viewport: { width: 560, height: 400 }, deviceScaleFactor: 2 });
  await page.goto(`file://${file}`);
  await page.waitForLoadState('networkidle');
  await page.screenshot({ path: out, fullPage: true });
  await page.close();
  fs.rmSync(file);
}

// ---------- Images ----------

/** The opaque part of a window capture (the capture includes the window's shadow): { x, y, w, h } in pixels */
function opaqueBox(png) {
  const g = execFileSync('magick', [png, '-alpha', 'extract', '-threshold', '99%', '-format', '%@', 'info:']).toString();
  const [, w, h, x, y] = g.match(/(\d+)x(\d+)\+(\d+)\+(\d+)/).map(Number);
  return { x, y, w, h };
}

/** The page with the panel where the app puts it after a drag: 16 pt right of and below the end of the drag */
function composeLookup(screenPng, sel, panelPng, scale, screen, out) {
  const box = opaqueBox(panelPng);
  const pw = box.w / scale, ph = box.h / scale;
  const px = Math.min(sel.x + sel.w + 16, screen.w - pw - 10), py = Math.min(sel.y + sel.h + 16, screen.h - ph - 10);
  const left = Math.max(0, Math.min(sel.x - 300, px - 60)), top = Math.max(0, sel.y - 150);
  const right = Math.min(screen.w, Math.max(sel.x + sel.w + 300, px + pw + 120)), bottom = Math.min(screen.h, py + ph + 70);
  const at = (v) => Math.round(v * scale);
  execFileSync('magick', [screenPng, panelPng, '-geometry', `+${at(px) - box.x}+${at(py) - box.y}`, '-composite',
    '-crop', `${at(right - left)}x${at(bottom - top)}+${at(left)}+${at(top)}`, '+repage', out]);
}

// ---------- Run ----------

const work = fs.mkdtempSync(path.join(os.tmpdir(), 'readme-shots-'));
if (!process.argv.includes('--no-build')) {
  console.log('Building the README copy (build/Readme)…');
  execFileSync('xcodegen', ['generate'], { cwd: root, stdio: 'ignore' });
  const log = path.join(work, 'build.log');
  try {
    execFileSync('sh', ['-c', `xcodebuild -project GetNewWord.xcodeproj -scheme GetNewWord -configuration Debug -derivedDataPath build/Readme -destination "platform=macOS,arch=$(uname -m)" CODE_SIGNING_ALLOWED=NO PRODUCT_NAME=GetNewWord PRODUCT_BUNDLE_IDENTIFIER=${bundleId} build > "${log}" 2>&1`], { cwd: root });
  } catch {
    console.error(fs.readFileSync(log, 'utf8').split('\n').filter((l) => /error:/.test(l)).join('\n') || `build failed, see ${log}`);
    process.exit(1);
  }
}

if (!fs.existsSync(app)) { console.error(`${app} is missing: run without --no-build once.`); process.exit(1); }

const screen = screenSize();
const browser = await chromium.launch({ channel: 'chrome', headless: true });
let ankiChild = null, appChild = null;
try {
  for (const lang of langs) {
    const cfg = LANGS[lang];
    const dir = path.join(work, lang);
    const outDir = path.join(root, 'docs/readme', lang);
    fs.mkdirSync(dir, { recursive: true });
    fs.mkdirSync(outDir, { recursive: true });

    // 1. Demo pages as full-screen images, and where each marked word is (points, top-left origin).
    const lookups = [];
    const page = await browser.newPage({ viewport: { width: screen.w, height: screen.h }, deviceScaleFactor: screen.scale });
    for (const [i, html] of cfg.pages.entries()) {
      await page.setContent(html);
      await page.evaluate(() => document.fonts.ready);
      const png = path.join(dir, `screen-${i}.png`);
      await page.screenshot({ path: png });
      const words = await page.evaluate(() => [...document.querySelectorAll('[data-w]')].map((e) => {
        const r = e.getBoundingClientRect();
        return { n: +e.dataset.w, word: e.textContent, x: r.left - 4, y: r.top - 3, w: r.width + 8, h: r.height + 6 };
      }));
      for (const w of words) lookups.push({ ...w, screen: png });
    }
    await page.close();
    lookups.sort((a, b) => a.n - b.n);
    const plan = path.join(dir, 'plan.json');
    fs.writeFileSync(plan, JSON.stringify({ pause: 14, lookups: lookups.map((l) => ({ screen: l.screen, select: [l.x, l.y, l.w, l.h].map((v) => Math.round(v * 10) / 10) })) }));

    // 2. A fresh copy: no words, setup done, DeepSeek, no auto-speak, no floating button.
    resetCopy();
    defaults('write', 'hasCompletedOnboarding', '-bool', 'true');
    defaults('write', 'uiLanguageMigrated', '-bool', 'true');
    defaults('write', 'AppleLanguages', '-array', cfg.ui);
    defaults('write', 'targetLanguage', '-string', cfg.target);
    defaults('write', 'apiProvider', '-string', 'deepseek');
    defaults('write', 'autoSpeak', '-bool', 'false');
    defaults('write', 'showFloatingButton', '-bool', 'false');
    defaults('write', 'appearance', '-string', 'light');
    defaults('write', 'usageConsent', '-string', 'no'); // answered, so the main window doesn't ask about anonymous stats

    const ankiBase = path.join(dir, 'anki');
    ankiChild = await startAnki(ankiBase, path.join(dir, 'anki.log'));

    // 3. Frame every word; capture the panel a few seconds after each one.
    console.log(`${lang}: framing ${lookups.length} words…`);
    appChild = launch({ GNW_DEMO: plan, GNW_DEMO_KEY: key }, path.join(dir, 'app.out'));
    await mainWindow(appChild);
    for (let i = 1; i <= lookups.length; i++) {
      await waitFor(`lookup ${i}`, () => {
        const log = appLog();
        const failed = log.match(/\[Analysis\] ✗ .*/);
        if (failed) throw new Error(`lookup ${i} failed: ${failed[0]}`);
        return log.includes(`[Demo] ${i}/${lookups.length} done`);
      }, 120000);
      await sleep(6000);
      const panel = windowsOf(appChild.pid).find((w) => w.layer === 3 && w.w >= 300);
      if (!panel) throw new Error(`no panel after lookup ${i}`);
      capture(panel.id, path.join(dir, `panel-${i}.png`));
      console.log(`  ${i}. ${lookups[i - 1].word}`);
    }
    await waitFor('the end of the demo', () => appLog().includes('[Demo] all done'), 60000);
    await quit(appChild);
    const sel = lookups[cfg.panel - 1];
    composeLookup(sel.screen, sel, path.join(dir, `panel-${cfg.panel}.png`), screen.scale, screen, path.join(outDir, 'lookup.png'));

    // 4. The word book, opened afresh (it selects the newest word), in light and dark.
    for (const look of ['light', 'dark']) {
      defaults('write', 'appearance', '-string', look);
      appChild = launch({}, path.join(dir, 'app.out'));
      const win = await mainWindow(appChild);
      await sleep(6000);
      capture(win.id, path.join(outDir, `main-${look}.png`));
      await quit(appChild);
    }

    // 5. The card Anki made for the panel's word.
    const notes = await anki('findNotes', { query: 'deck:*' });
    console.log(`  Anki: ${notes.length} notes`);
    if (cfg.card) await renderCard(browser, ankiBase, sel.word, path.join(outDir, 'anki-card.png'));
    await stopAnki(ankiChild);
    ankiChild = null;
    for (const f of fs.readdirSync(outDir).filter((f) => f.endsWith('.png'))) console.log(`  docs/readme/${lang}/${f}`);
  }
} finally {
  if (appChild) await quit(appChild);
  if (ankiChild) await stopAnki(ankiChild);
  await browser.close();
  resetCopy();
  if (!process.env.KEEP_WORK) fs.rmSync(work, { recursive: true, force: true }); else console.log('work files kept in', work);
}
