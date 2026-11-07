const { chromium } = require('playwright');
const { spawn } = require('child_process');
const http = require('http');
const fs = require('fs');

async function waitForServerAsync(url, maxMs) {
  const start = Date.now();
  return new Promise((resolve) => {
    const check = () => {
      const req = http.get(url, (r) => { r.resume(); resolve(true); });
      req.on('error', () => {
        if (Date.now() - start > maxMs) return resolve(false);
        setTimeout(check, 500);
      });
      req.setTimeout(2000, () => { req.destroy(); setTimeout(check, 500); });
    };
    check();
  });
}

async function main() {
  const stub = spawn('python3', ['scripts/stub_api.py'], { detached: true, stdio: 'ignore' });
  stub.unref();
  const stubOk = await waitForServerAsync('http://localhost:9473/today', 15000);
  if (!stubOk) throw new Error('stub API failed to start');

  // Use scripts/serve.py: it serves .wasm as application/wasm, which is what
  // CanvasKit's WebAssembly.instantiateStreaming needs. The plain
  // `python3 -m http.server` returns text/plain for .wasm and the engine
  // aborts before any canvas appears.
  const staticServer = spawn('python3', ['scripts/serve.py', 'build/web', '9474'], { detached: true, stdio: 'ignore' });
  staticServer.unref();
  const staticOk = await waitForServerAsync('http://localhost:9474', 15000);
  if (!staticOk) throw new Error('static server failed to start');

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

  // Surface every console message so a failed render is diagnosable from CI
  // logs without guessing. The app itself beacons startup stages to /diag.
  page.on('console', (msg) => console.log('[browser]', msg.type(), msg.text()));
  page.on('pageerror', (err) => console.error('[pageerror]', err.message));

  await page.goto('http://localhost:9474', { waitUntil: 'domcontentloaded' });

  // The modern Flutter bootstrap writes the canvas into #window. Wait for it
  // to be visible before screenshotting; if it never appears, fail loudly with
  // a diagnostic screenshot instead of a silent timeout.
  try {
    await page.waitForSelector('canvas', { timeout: 30000 });
  } catch (e) {
    const diag = 'screenshots/diagnostic.png';
    fs.mkdirSync('screenshots', { recursive: true });
    await page.screenshot({ path: diag });
    throw new Error(`No canvas rendered within 30s. Diagnostic saved to ${diag}.`);
  }

  // Wait for Flutter to finish laying out the first frame.
  await page.waitForTimeout(5000);

  fs.mkdirSync('screenshots', { recursive: true });

  // home.png
  await page.screenshot({ path: 'screenshots/home.png' });

  // goals.png — click a goal chip (approximate coordinates)
  try {
    await page.click('canvas', { position: { x: 150, y: 170 } });
    await page.waitForTimeout(1500);
  } catch (e) {}
  await page.screenshot({ path: 'screenshots/goals.png' });

  // Go back to all tasks
  try {
    await page.click('canvas', { position: { x: 90, y: 170 } });
    await page.waitForTimeout(1500);
  } catch (e) {}

  // task_detail.png — click a task row (approximate)
  try {
    await page.click('canvas', { position: { x: 195, y: 280 } });
    await page.waitForTimeout(2500);
    await page.screenshot({ path: 'screenshots/task_detail.png' });
    // Go back
    await page.click('canvas', { position: { x: 30, y: 60 } });
    await page.waitForTimeout(1500);
  } catch (e) {}

  await browser.close();

  try { process.kill(-stub.pid, 'SIGKILL'); } catch (e) {}
  try { process.kill(-staticServer.pid, 'SIGKILL'); } catch (e) {}
  process.exit(0);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});