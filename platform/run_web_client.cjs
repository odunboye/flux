// Executes the Idris-generated Flux UI Web client, either in Node's fetch runtime
// or a real Chromium page. Test harness only; not part of the generated client.
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const http = require('node:http');
const { createRequire } = require('node:module');

const [base, mode = 'smoke', target = 'node'] = process.argv.slice(2);
if (!base || !['smoke', 'pooled', 'crud'].includes(mode) || !['node', 'browser'].includes(target)) {
  throw new Error('usage: node run_web_client.cjs BASE_URL [smoke|pooled|crud] [node|browser]');
}
const executable = mode === 'crud' ? 'crud/build/exec/platform-crud-client-test' : 'example/build/exec/platform-client-web-test';
const source = fs.readFileSync(path.join(__dirname, executable), 'utf8');

async function browserTest() {
  const fluxUI = process.env.FLUX_UI_ROOT || path.resolve(__dirname, '../packages/ui');
  const { chromium } = createRequire(path.join(fluxUI, 'package.json'))('@playwright/test');
  const server = http.createServer((req, res) => {
    res.writeHead(200, { 'Content-Type': 'text/html' });
    res.end('<!doctype html><title>Flux UI generated client test</title>');
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  let browser;
  try {
    browser = await chromium.launch({ headless: true });
    const page = await browser.newPage();
    page.on('console', message => console.log(message.text()));
    page.on('pageerror', error => console.error(error));
    await page.goto(`http://127.0.0.1:${server.address().port}/`);
    await page.evaluate(({ base, pooled }) => {
      globalThis.__rpcTestBase = base;
      globalThis.__rpcTestPooled = pooled;
    }, { base, pooled: mode === 'pooled' });
    // Cross-origin JSON POSTs exercise actual browser CORS/preflight handling.
    await page.addScriptTag({ content: source });
    await page.waitForFunction(() => globalThis.__rpcTestResult !== undefined, undefined, { timeout: 30000 });
    if (await page.evaluate(() => globalThis.__rpcTestResult) !== 1) throw new Error('Flux UI browser checks failed');
    console.log('PASS real Chromium Flux UI client and cross-origin preflight');
  } finally {
    if (browser) await browser.close();
    await new Promise(resolve => server.close(resolve));
  }
}

if (target === 'browser') {
  browserTest().catch(error => { console.error(error); process.exitCode = 1; });
} else {
  globalThis.__rpcTestBase = base;
  globalThis.__rpcTestPooled = mode === 'pooled';
  const deadline = setTimeout(() => { console.error('Flux UI client timed out'); process.exit(1); }, 30000);
  const watcher = setInterval(() => {
    if (globalThis.__rpcTestResult !== undefined) {
      clearTimeout(deadline);
      clearInterval(watcher);
      process.exitCode = globalThis.__rpcTestResult === 1 ? 0 : 1;
    }
  }, 20);
  vm.runInThisContext(source, { filename: 'platform-client-web-test' });
}
