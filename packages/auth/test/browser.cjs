const assert = require('node:assert/strict');
const path = require('node:path');
const {createRequire} = require('node:module');
const {chromium} = createRequire(path.resolve(__dirname, '../../ui/package.json'))('@playwright/test');
const base = process.argv[2];
const password = 'browser correct horse battery';
(async () => {
  const browser = await chromium.launch({headless:true});
  try {
    const contexts = [await browser.newContext(), await browser.newContext()];
    const pages = await Promise.all(contexts.map(c => c.newPage()));
    for (const p of pages) await p.goto(base);
    const call = (page, route, body = {}, token = null) => page.evaluate(async ({route,body,token}) => {
      const headers = {'Content-Type':'application/json'};
      if (token) headers.Authorization = 'Bearer '+token;
      const r = await fetch('/rpc/v1/'+route, {method:'POST',headers,body:JSON.stringify(body),credentials:'omit'});
      return {status:r.status,body:await r.json(),cache:r.headers.get('Cache-Control'),cors:r.headers.get('Access-Control-Allow-Origin')};
    }, {route,body,token});
    const sessions = [];
    for (let i = 0; i < 2; i++) {
      const credentials = {username:'browser_'+i,password};
      const registered = await call(pages[i], 'auth/register', credentials);
      assert.equal(registered.status, 200);
      const login = await call(pages[i], 'auth/login', credentials);
      assert.equal(login.status,200); assert.equal(login.cache,'no-store'); assert.equal(login.cors,null);
      sessions.push(login.body);
      const me = await call(pages[i], 'auth/me', {}, login.body.token);
      assert.deepEqual(me.body, registered.body);
      assert.deepEqual(await contexts[i].cookies(), []);
      assert.deepEqual(await pages[i].evaluate(() => [localStorage.length,sessionStorage.length]), [0,0]);
    }
    assert.notEqual(sessions[0].account.id,sessions[1].account.id);
    const probe = await call(pages[0], 'probe/private', {claimedOwner:sessions[1].account.id}, sessions[0].token);
    assert.equal(probe.body.resolvedOwner,sessions[0].account.id);
    assert.equal((await call(pages[0], 'auth/logout', {}, sessions[0].token)).status,200);
    assert.equal((await call(pages[0], 'auth/me', {}, sessions[0].token)).status,401);
    assert.equal((await call(pages[1], 'auth/me', {}, sessions[1].token)).status,200);
    console.log('PASS two Chromium contexts: register/login, real principal, scoped logout, no credential storage/cookies, no wildcard CORS');
  } finally { await browser.close(); }
})().catch(e => { console.error(e); process.exitCode=1; });
