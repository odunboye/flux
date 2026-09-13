const {chromium, expect} = require('../../packages/ui/node_modules/@playwright/test');
const assert = require('node:assert/strict');
(async()=>{
  const browser=await chromium.launch({headless:true});
  try {
    const page=await browser.newPage();
    const errors=[]; page.on('pageerror', e=>errors.push(e.message));
    await page.clock.install();
    const base='http://127.0.0.1:'+process.argv[2];
    await page.goto(base);
    await expect(page.getByText('Version one',{exact:true})).toBeVisible();
    await page.evaluate(()=>window.marker='same document');
    await page.getByRole('textbox',{name:'Draft'}).fill('retain draft');
    await page.getByRole('button',{name:'Increment',exact:true}).click();
    await expect(page.getByText('Count 1',{exact:true})).toBeVisible();
    await page.getByRole('button',{name:'Start effect'}).click();
    await page.getByRole('button',{name:'Hold',exact:true}).click();
    await expect(page.getByRole('button',{name:'Release',exact:true})).toBeVisible();
    await page.request.post(base+'/__test/2');
    await expect(page.locator('#flux-dev-status')).toContainText('Waiting for the application');
    await expect(page.getByText('Version one',{exact:true})).toBeVisible();
    await page.route('**/app.js?flux_hmr=*', route=>route.abort());
    await page.getByRole('button',{name:'Release',exact:true}).click();
    await expect(page.locator('#flux-dev-status')).toContainText('Previous UI retained');
    await expect(page.getByText('Version one',{exact:true})).toBeVisible();
    await page.unroute('**/app.js?flux_hmr=*');
    await expect(page.getByText('Version two',{exact:true})).toBeVisible();
    await expect(page.getByText('Count 1',{exact:true})).toBeVisible();
    await expect(page.getByRole('textbox',{name:'Draft'})).toHaveValue('retain draft');
    assert.equal(await page.evaluate(()=>window.marker),'same document');
    assert.equal(await page.evaluate(()=>window.__hotStarts),1); // no init replay
    assert.equal(await page.evaluate(()=>window.__hotCancelled),1);
    await page.evaluate(()=>window.__hotCallbacks.forEach(send=>send()));
    await page.waitForTimeout(100);
    await expect(page.getByText('Count 1',{exact:true})).toBeVisible(); // old effect rejected
    await page.getByRole('button',{name:'Increment',exact:true}).click();
    await expect(page.getByText('Count 3',{exact:true})).toBeVisible(); // new update implementation
    assert.equal(await page.evaluate(()=>window.__fluxUITimers.size),2); // one render + one tick
    assert.equal(await page.evaluate(()=>document.adoptedStyleSheets.length),1);
    await page.clock.pauseAt(new Date());
    const ticks=async()=>Number((await page.getByText(/^Ticks \d+$/).innerText()).split(' ')[1]);
    const before=await ticks();
    await page.clock.runFor(1000);
    const delta=(await ticks())-before;
    assert(delta>=9&&delta<=11, 'Exactly one active tick chain');
    await page.clock.resume();
    await page.request.post(base+'/__test/3');
    await expect(page.getByText('Version three',{exact:true})).toBeVisible();
    await expect(page.getByText('Count 0',{exact:true})).toBeVisible();
    await expect(page.getByRole('textbox',{name:'Draft'})).toHaveValue('');
    assert.equal(await page.evaluate(()=>window.marker),undefined);
    await page.evaluate(()=>window.marker='decoder boundary');
    await page.getByRole('button',{name:'Increment',exact:true}).click();
    await expect(page.getByText('Count 3',{exact:true})).toBeVisible();
    await page.request.post(base+'/__test/4');
    await expect(page.getByText('Version four',{exact:true})).toBeVisible();
    await expect(page.getByText('Count 0',{exact:true})).toBeVisible();
    assert.equal(await page.evaluate(()=>window.marker),undefined); // decoder rejected, even with equal version
    await page.evaluate(()=>window.marker='plain boundary');
    await page.request.post(base+'/__test/5');
    await expect(page.getByText('Plain version',{exact:true})).toBeVisible();
    assert.equal(await page.evaluate(()=>window.marker),undefined); // runWeb did not mount over the old runtime
    assert.equal(await page.evaluate(()=>window.__hotStarts),1);
    assert.equal(await page.evaluate(()=>window.__fluxUITimers.size),2);
    assert.equal(await page.evaluate(()=>localStorage.length+sessionStorage.length),0);
    assert.deepEqual(errors,[]);
    console.log('PASS real Idris HMR: state, new update/view, busy deferral, cancellation, stale callbacks, timer/style cleanup, no init replay, incompatible reload');
  } finally {await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1});
