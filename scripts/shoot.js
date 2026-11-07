#!/usr/bin/env node
// shoot.js — Playwright screenshots of the vector-tasks Flutter web app.
//
// Why the previous version produced blank, identical screenshots:
//   It waited for the <canvas> element and then slept a fixed 5 seconds.
//   Flutter needs that window to load prefs, hit /goals, /goals/:id/tasks,
//   /today and /calendar/range, and only then flips _loading=false and
//   repaints the canvas. The 5 s expired mid-flight, so every shot captured
//   the loading state (or an identical frame), and task_detail.png was never
//   produced because the blind clicks landed on the wrong coordinates.
//
// What this version does instead:
//   1. Waits for the canvas AND for the stub-API data requests to complete
//      (monitored via the network).
//   2. After data arrives, waits for the canvas to actually repaint by
//      comparing MD5 hashes against the known-blank fingerprint
//      (MD5 6b967c35dd81247813ba7234b0bd28b3). Much simpler than pixel heuristics.
//   3. Navigates by clicking with coordinates derived from the real layout
//      (header ~104px, LISTS label, chip row ~y=133, first task row ~y=258),
//      and re-verifies the canvas MD5 changed after each step.
//   4. Fails the run if fewer than 3 distinct, non-blank screenshots result.
//
const { chromium } = require('playwright');
const { spawn } = require('child_process');
const crypto = require('crypto');
const http = require('http');
const fs = require('fs');

const STUB_PORT = 9473;
const WEB_PORT = 9474;
const KNOWN_BLANK_MD5 = '6b967c35dd81247813ba7234b0bd28b3';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

async function waitForServer(url, maxMs = 15000) {
  const start = Date.now();
  return new Promise((resolve) => {
    const tick = () => {
      const req = http.get(url, (r) => { r.resume(); resolve(true); });
      req.on('error', () => {
        if (Date.now() - start > maxMs) return resolve(false);
        setTimeout(tick, 500);
      });
      req.setTimeout(2000, () => { req.destroy(); setTimeout(tick, 500); });
    };
    tick();
  });
}

function md5hex(buf) {
  return crypto.createHash('md5').update(buf).digest('hex');
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

async function main() {
  fs.mkdirSync('screenshots', { recursive: true });

  // --- Servers ---
  const stub = spawn('python3', ['scripts/stub_api.py'], { stdio: 'ignore' });
  if (!(await waitForServer(`http://localhost:${STUB_PORT}/today`))) {
    throw new Error('stub API failed to start');
  }
  const staticSrv = spawn('python3', ['scripts/serve.py', 'build/web', String(WEB_PORT)], { stdio: 'ignore' });
  if (!(await waitForServer(`http://localhost:${WEB_PORT}`))) {
    throw new Error('static server failed to start');
  }
  console.log('[shoot] servers up');

  // --- Browser ---
  const browser = await chromium.launch({
    headless: true,
    args: [
      '--use-gl=angle',
      '--use-angle=swiftshader',
      '--enable-unsafe-swiftshader',
      '--disable-dev-shm-usage',
    ],
  });
  const context = await browser.newContext({
    viewport: { width: 390, height: 844 },
    deviceScaleFactor: 2,
  });
  const page = await context.newPage();
  page.on('console', (m) => console.log('[browser]', m.type(), m.text()));
  page.on('pageerror', (e) => console.error('[pageerror]', e.message));

  // --- Track data requests to the stub API ---
  const apiFlags = new Set();
  const apiFailures = [];
  page.on('response', (res) => {
    if (!res.url().includes(`:${STUB_PORT}`)) return;
    const path = new URL(res.url()).pathname;
    if (res.ok()) {
      if (path === '/goals') apiFlags.add('goals');
      else if (path.startsWith('/goals/') && path.endsWith('/tasks')) apiFlags.add('goal_tasks');
      else if (path === '/today') apiFlags.add('today');
      else if (path === '/calendar/range') apiFlags.add('calendar');
    } else {
      apiFailures.push(`${res.status()} ${path}`);
    }
  });
  page.on('requestfailed', (req) => {
    if (req.url().includes(`:${STUB_PORT}`)) {
      apiFailures.push(`FAILED ${req.url()} (${req.failure()?.errorText || 'unknown'})`);
    }
  });

  // --- Load the app ---
  await page.goto(`http://localhost:${WEB_PORT}`, {
    waitUntil: 'domcontentloaded',
    timeout: 60000,
  });

  try {
    await page.waitForSelector('canvas', { timeout: 45000 });
  } catch (e) {
    await page.screenshot({ path: 'screenshots/diagnostic.png' });
    throw new Error('No canvas within 45s — Flutter never initialised');
  }
  console.log('[shoot] canvas appeared');

  // --- Wait for data endpoints ---
  const start = Date.now();
  const dataReady = new Promise((resolve) => {
    const tick = () => {
      if (apiFlags.has('goals') && apiFlags.has('goal_tasks') && apiFlags.has('today')) return resolve(true);
      if (Date.now() > start + 30000) return resolve(false);
      setTimeout(tick, 250);
    };
    tick();
  });
  const gotData = await Promise.race([
    dataReady,
    new Promise((r) => setTimeout(() => r(false), 30000)),
  ]);
  console.log(`[shoot] API flags: ${[...apiFlags].join(',') || '(none)'}`);
  if (apiFailures.length) console.log('[shoot] API failures:', apiFailures);
  if (!gotData) {
    console.error('[shoot] ERROR: stub API data never arrived — screenshots will be blank');
    await page.screenshot({ path: 'screenshots/diagnostic.png' });
    throw new Error('API data not loaded within 30s');
  }

  // --- Wait for the canvas to actually repaint (MD5 differs from known blank) ---
  // The known-blank MD5 (6b967c35…) is the exact fingerprint of the loading frame.
  // Once Flutter processes the data and calls setState, the canvas repaints and
  // the MD5 changes. We poll until it does.
  let painted = false;
  for (let attempt = 1; attempt <= 6; attempt++) {
    await page.waitForTimeout(attempt === 1 ? 2000 : 1500);
    const shot = await page.screenshot({ type: 'png' });
    const hash = md5hex(shot);
    console.log(`[shoot] paint check #${attempt}: md5=${hash}`);
    if (hash !== KNOWN_BLANK_MD5) {
      painted = true;
      break;
    }
  }
  if (!painted) {
    console.error('[shoot] ERROR: canvas never repainted after data load (still blank)');
    await page.screenshot({ path: 'screenshots/diagnostic.png' });
    throw new Error('canvas still blank after 11s post-data — Flutter did not rebuild');
  }
  console.log('[shoot] canvas repainted with real data');
  await page.waitForTimeout(800);

  // ------------------------------------------------------------------
  // 1. home.png — home screen, "All tasks" selected, data visible
  // ------------------------------------------------------------------
  await page.screenshot({ path: 'screenshots/home.png' });
  console.log('[shoot] saved home.png');

  // ------------------------------------------------------------------
  // 2. goals.png — select the first goal chip ("Ship vector-tasks v2")
  //    Layout (CSS px, 390x844 viewport):
  //      header block ends ~y=104 (28 top pad + 13 + 8 + ~46 title + 18 gap)
  //      LISTS label at ~y=112, chip row at ~y=132 (9px vertical pad)
  //      "All tasks · 8" chip spans x=24..~118; first goal chip starts
  //      ~x=126 (8px gap). Click center of that chip: x~195, y~133.
  // ------------------------------------------------------------------
  await page.click('canvas', { position: { x: 195, y: 133 }, delay: 20 });
  await page.waitForTimeout(1500);

  // Verify the canvas actually changed (different MD5 = different screen)
  const beforeGoals = md5hex(await page.screenshot({ type: 'png' }));
  let goalsPainted = false;
  for (let attempt = 1; attempt <= 4; attempt++) {
    await page.waitForTimeout(800);
    const afterGoals = md5hex(await page.screenshot({ type: 'png' }));
    if (afterGoals !== beforeGoals) {
      goalsPainted = true;
      break;
    }
  }
  if (!goalsPainted) {
    console.warn('[shoot] WARNING: goals.png may be identical to home.png (canvas did not change after chip click)');
  }

  await page.screenshot({ path: 'screenshots/goals.png' });
  console.log('[shoot] saved goals.png');

  // ------------------------------------------------------------------
  // 3. task_detail.png — back to "All tasks", then open the first task row
  //    Filter row at ~y=160-186; section heading ~y=204; first task row
  //    top ~y=222 (row content ~32px + 13px vertical padding).
  //    Click the row body (x=195 avoids the 24px checkbox on the left).
  // ------------------------------------------------------------------
  await page.click('canvas', { position: { x: 70, y: 133 }, delay: 20 });
  await page.waitForTimeout(1500);

  await page.click('canvas', { position: { x: 195, y: 258 }, delay: 20 });
  await page.waitForTimeout(3000); // detail page route transition + layout

  // Verify the detail page actually painted
  const beforeDetail = md5hex(await page.screenshot({ type: 'png' }));
  let detailPainted = false;
  for (let attempt = 1; attempt <= 4; attempt++) {
    await page.waitForTimeout(800);
    const afterDetail = md5hex(await page.screenshot({ type: 'png' }));
    if (afterDetail !== beforeDetail) {
      detailPainted = true;
      break;
    }
  }
  if (!detailPainted) {
    console.warn('[shoot] WARNING: task_detail.png may be identical to previous (canvas did not change after task click)');
  }

  await page.screenshot({ path: 'screenshots/task_detail.png' });
  console.log('[shoot] saved task_detail.png');

  await browser.close();
  stub.kill('SIGKILL');
  staticSrv.kill('SIGKILL');

  // ------------------------------------------------------------------
  // Final verification: 3 screenshots, all unique MD5s, none match blank
  // ------------------------------------------------------------------
  const names = ['home.png', 'goals.png', 'task_detail.png'];
  const hashes = [];
  for (const name of names) {
    const buf = fs.readFileSync(`screenshots/${name}`);
    const hash = md5hex(buf);
    hashes.push({ name, hash, size: buf.length });
    const isBlank = (hash === KNOWN_BLANK_MD5);
    console.log(`  ${name}: md5=${hash} size=${buf.length} ${isBlank ? '⚠ BLANK' : 'OK'}`);
  }
  const uniq = new Set(hashes.map((h) => h.hash));
  if (uniq.size < 3) {
    throw new Error(`screenshots are not all distinct (${uniq.size}/3 unique) — capture failed`);
  }
  const blank = hashes.filter((h) => h.hash === KNOWN_BLANK_MD5);
  if (blank.length) {
    throw new Error(`blank screenshot(s) detected: ${blank.map((b) => b.name).join(', ')}`);
  }
  console.log('[shoot] OK — 3 distinct, non-blank screenshots');
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});