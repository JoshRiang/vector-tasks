const { chromium } = require('playwright');
const { spawn } = require('child_process');
const http = require('http');

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

  const staticServer = spawn('python3', ['-m', 'http.server', '9474', '--directory', 'build/web'], { detached: true, stdio: 'ignore' });
  staticServer.unref();
  const staticOk = await waitForServerAsync('http://localhost:9474', 15000);
  if (!staticOk) throw new Error('static server failed to start');

  // Give Flutter web time to load
  await new Promise(r => setTimeout(r, 10000));

  const browser = await chromium.launch({ headless: true });
  const context = await browser.newContext({
    viewport: { width: 390, height: 844 },
    deviceScaleFactor: 2,
  });
  const page = await context.newPage();

  await page.goto('http://localhost:9474', { waitUntil: 'networkidle' });
  await page.waitForSelector('canvas', { timeout: 15000 });
  // Wait for Flutter to render content on canvas
  await page.waitForTimeout(8000);

  const fs = require('fs');
  fs.mkdirSync('screenshots', { recursive: true });

  // home.png
  await page.screenshot({ path: 'screenshots/home.png' });

  // goals.png — click a goal chip (approximate coordinates)
  // The list chips are at around y=160. Click on the second chip (a goal).
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
    // The back button is in the navigation bar top-left
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
