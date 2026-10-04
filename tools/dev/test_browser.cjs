const {chromium, expect} = require('@playwright/test');
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
(async()=>{
  const browser=await chromium.launch({headless:true});
  try {
    const page=await browser.newPage();
    const errors=[];
    page.on('pageerror', error=>errors.push(error.message));
    await page.goto('http://127.0.0.1:'+process.argv[2]);
    const edit=(name,value)=>fs.writeFileSync(path.join(process.argv[3],name),value);
    const draft=page.getByRole('textbox',{name:'Draft'});
    await draft.fill('keep this draft');
    await page.evaluate(()=>window.sentinel='preserved');
    edit('app.css','body{background:rgb(1,2,3)}');
    await expect(page.locator('body')).toHaveCSS('background-color','rgb(1, 2, 3)');
    await expect(draft).toHaveValue('keep this draft');
    assert.equal(await page.evaluate(()=>window.sentinel),'preserved');
    edit('ui.idr','FAIL');
    await expect(page.locator('#flux-dev-status')).toContainText('Compilation failed');
    await expect(page.locator('#flux-dev-status')).toContainText('<script>unsafe compiler output</script>');
    await expect(page.locator('#flux-dev-status script')).toHaveCount(0);
    await expect(draft).toHaveValue('keep this draft');
    await expect(page.locator('body')).toHaveCSS('background-color','rgb(1, 2, 3)');
    edit('ui.idr','fixed browser build');
    await expect(draft).toHaveValue('');
    await expect(page.locator('#flux-dev-status')).toBeHidden();
    assert.equal(await page.evaluate(()=>window.sentinel),undefined);
    await page.route('**/__flux_dev/status', route=>route.abort());
    await expect(page.locator('#flux-dev-status')).toContainText('Reconnecting');
    await page.unroute('**/__flux_dev/status');
    await expect(page.locator('#flux-dev-status')).toBeHidden();
    assert.deepEqual(errors,[]);
    console.log('PASS live-reload browser: CSS preserves state, errors render safely, JS reloads, polling reconnects');
  } finally {await browser.close();}
})().catch(error=>{console.error(error);process.exitCode=1});
