// Smoke-test a packaged Iris release; requires this repo's own root Playwright install.
const {chromium,expect}=require('@playwright/test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const http=require('node:http');
(async()=>{
 const root=path.resolve(process.argv[2]);
 const server=http.createServer((req,res)=>{
  const name=new URL(req.url,'http://localhost').pathname.replace(/\/$/,'/index.html');
  const file=path.resolve(root,'.'+name);
  if(!file.startsWith(root+path.sep)||!fs.existsSync(file)||!fs.statSync(file).isFile()){res.writeHead(404);res.end();return;}
  const mime={'.js':'text/javascript','.html':'text/html','.css':'text/css','.svg':'image/svg+xml','.png':'image/png'};
  res.setHeader('Content-Type',mime[path.extname(file)]||'application/octet-stream');res.end(fs.readFileSync(file));
 });
 await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));let browser;
 try {
  browser=await chromium.launch({headless:true});const page=await browser.newPage({viewport:{width:390,height:844}});const errors=[];
  page.on('pageerror',error=>errors.push(error.message));
  await page.goto('http://127.0.0.1:'+server.address().port);
  await expect(page.locator('#iris-app button').first()).toBeVisible();
  const status=await page.evaluate(()=>globalThis.IdrisCapacitor.call('Network','getStatus'));
  assert.equal(typeof status.connected,'boolean');
  assert.equal(await page.evaluate(()=>Boolean(globalThis.__fluxHot)),false);
  assert.deepEqual(errors,[]);
  console.log('PASS packaged Iris boots with registered Capacitor plugins and no dev HMR runtime');
 }finally{if(browser)await browser.close();await new Promise(resolve=>server.close(resolve));}
})().catch(error=>{console.error(error);process.exitCode=1;});
