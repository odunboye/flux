// Actual Flux UI DOM application, not a standalone generated-client smoke test.
const {chromium, expect} = require('../packages/ui/node_modules/@playwright/test');
const assert = require('node:assert/strict');
const [base, mode = 'lifecycle'] = process.argv.slice(2);
(async () => {
  const browser = await chromium.launch({headless: true});
  try {
    for (const path of ['/workspace.json', '/flux.json', '/Main.idr', '/../../pack.toml']) {
      assert.equal((await fetch(base + path)).status, 404, 'development assets must be allowlisted');
    }
    assert.equal((await fetch(base + '/rpc/v1/todos/create', {method:'POST', headers:{Origin:'https://untrusted.example'}, body:'{"title":"forbidden"}'})).status, 403);
    assert.equal((await fetch(base + '/rpc/v1/todos/create', {method:'POST', body:'x'.repeat(65537)})).status, 413);
    const page = await browser.newPage();
    let bearer;
    page.on('response', async response => {
      if (response.url().endsWith('/auth/login') && response.status()===200) {
        const session=await response.json();
        if(session.account.username==='cli_account') bearer=session.token;
      }
    });
    const signIn = async () => {
      await page.getByLabel('Username',{exact:true}).fill('cli_account');
      await page.getByLabel('Password',{exact:true}).fill('CLI correct horse battery');
      await page.getByRole('button',{name:'Sign in',exact:true}).click();
    };
    const errors = [];
    page.on('pageerror', e => errors.push(e.message));
    let release;
    await page.route('**/rpc/v1/todos/list', async route => {
      await new Promise(resolve => { release = resolve; });
      await route.continue();
    });
    await page.goto(base);
    await expect(page.getByLabel('Password',{exact:true})).toHaveAttribute('type','password');
    if (mode==='lifecycle') {
      await page.getByLabel('Username',{exact:true}).fill('cli_account');
      await page.getByLabel('Password',{exact:true}).fill('CLI correct horse battery');
      await page.getByRole('button',{name:'Create account',exact:true}).click();
      await expect(page.getByText('Account created. Sign in.',{exact:true})).toBeVisible();
      await expect(page.getByLabel('Password',{exact:true})).toHaveValue('');
    }
    await signIn();
    await expect(page.getByText('Loading...', {exact:true})).toBeVisible();
    await expect.poll(() => Boolean(release)).toBeTruthy();
    release();
    await expect(page.getByText('Ready.', {exact:true})).toBeVisible();
    await page.unroute('**/rpc/v1/todos/list');
    if (mode === 'lifecycle') {
      const auth = await page.evaluate(async () => {
        const credentials = {username:'cli_proxy_account',password:'CLI correct horse battery'};
        const rpc = async (name,body,token) => {
          const headers = {'Content-Type':'application/json'};
          if(token) headers.Authorization='Bearer '+token;
          const r=await fetch('/rpc/v1/auth/'+name,{method:'POST',headers,body:JSON.stringify(body)});
          return {status:r.status,body:await r.json()};
        };
        const registered=await rpc('register',credentials);
        const login=await rpc('login',credentials);
        const me=await rpc('me',{},login.body.token);
        const logout=await rpc('logout',{},login.body.token);
        const revoked=await rpc('me',{},login.body.token);
        return {statuses:[registered.status,login.status,me.status,logout.status,revoked.status],
                same:registered.body.id===me.body.id, storage:[localStorage.length,sessionStorage.length]};
      });
      assert.deepEqual(auth.statuses,[200,200,200,200,401]);
      assert.equal(auth.same,true); assert.deepEqual(auth.storage,[0,0]);
      console.log('PASS fresh CLI app: real accounts, bearer forwarding, logout revocation through same-origin proxy');
    }
    await page.setViewportSize({width:390, height:844});
    const rows = page.getByRole('group', {name: /^Todo /});
    if (mode === 'pagination') {
      await expect(rows).toHaveCount(50);
      await page.route('**/rpc/v1/todos/list', route => route.abort('failed'));
      await page.getByRole('button', {name:'Load more', exact:true}).click();
      await expect(page.getByText('Connection failed. Refresh before retrying a write.', {exact:true})).toBeVisible();
      await expect(rows).toHaveCount(50);
      await page.unroute('**/rpc/v1/todos/list');
      await page.getByRole('button', {name:'Load more', exact:true}).click();
      await expect(rows).toHaveCount(56);
      await expect(page.getByRole('button', {name:'Load more', exact:true})).toHaveCount(0);
      const ids = await rows.evaluateAll(nodes => nodes.map(n => n.getAttribute('aria-label')));
      assert.equal(new Set(ids).size, 56);
      assert(ids.every(id => /^Todo 9223372036854775\d{3}$/.test(id)), ids);
      console.log('PASS Flux UI: real 50/6 keyset pages, unique exact BIGINT IDs');
    } else {
      await expect(page.getByText('No todos yet.', {exact:true})).toBeVisible();
      await page.getByRole('button', {name:'Add todo', exact:true}).click();
      await expect(page.getByText('Title must contain 1 to 128 characters.', {exact:true})).toBeVisible();
      const title = 'Flux UI 🚀 <script>window.uiInjected=true</script>';
      await page.getByRole('textbox', {name:'New todo title', exact:true}).fill(title);
      let creates = 0;
      page.on('request', req => { if(req.url().endsWith('/todos/create')) creates++; });
      await page.route('**/rpc/v1/todos/create', async route => {
        await new Promise(r => setTimeout(r, 300));
        await route.continue();
      });
      await page.getByRole('button', {name:'Add todo', exact:true}).dblclick();
      await expect(page.getByText('Working...', {exact:true})).toBeVisible();
      await expect(page.getByText('Created.', {exact:true})).toBeVisible();
      await page.unroute('**/rpc/v1/todos/create');
      assert.equal(creates, 1, 'busy state must prevent duplicate writes');
      await expect(rows).toHaveCount(1);
      await expect(page.getByText(title, {exact:true})).toBeVisible();
      assert.equal(await page.evaluate(() => globalThis.uiInjected), undefined);
      await page.getByRole('button', {name:'Edit '+title, exact:true}).click();
      await expect(page.getByRole('textbox', {name:'Edit todo title', exact:true})).toHaveValue(title);
      await page.getByRole('textbox', {name:'Edit todo title', exact:true}).fill('Cancelled draft');
      await page.getByRole('button', {name:'Cancel edit', exact:true}).click();
      await expect(page.getByText(title, {exact:true})).toBeVisible();
      await page.getByRole('button', {name:'Edit '+title, exact:true}).click();
      await page.getByRole('textbox', {name:'Edit todo title', exact:true}).fill('Saved title 🚀');
      await page.route('**/rpc/v1/todos/update', route => route.fulfill({status:400, contentType:'application/json',
        body:JSON.stringify({error:{code:'invalid_request',message:'Rejected for test'}})}));
      await page.getByRole('button', {name:'Save todo', exact:true}).click();
      await expect(page.getByText('Request rejected (400, invalid_request): Rejected for test', {exact:true})).toBeVisible();
      await expect(page.getByRole('textbox', {name:'Edit todo title', exact:true})).toHaveValue('Saved title 🚀');
      await page.unroute('**/rpc/v1/todos/update');
      await page.getByRole('button', {name:'Save todo', exact:true}).click();
      await expect(page.getByText('Saved.', {exact:true})).toBeVisible();
      await page.getByRole('checkbox', {name:'Complete Saved title 🚀', exact:true}).check();
      await expect(page.getByText('Complete', {exact:true})).toBeVisible();
      await page.getByRole('button', {name:'Delete Saved title 🚀', exact:true}).click();
      await page.getByRole('button', {name:'Keep todo', exact:true}).click();
      await expect(rows).toHaveCount(1);
      await page.getByRole('button', {name:'Delete Saved title 🚀', exact:true}).click();
      await page.getByRole('button', {name:'Confirm delete', exact:true}).click();
      await expect(page.getByText('No todos yet.', {exact:true})).toBeVisible();
      await page.getByRole('textbox', {name:'New todo title', exact:true}).fill('Removed by another client');
      await page.getByRole('button', {name:'Add todo', exact:true}).click();
      await expect(page.getByText('Created.', {exact:true})).toBeVisible();
      const missingId = (await rows.first().getAttribute('aria-label')).slice('Todo '.length);
      assert.equal((await fetch(base + '/rpc/v1/todos/delete', {method:'POST', headers:{'Content-Type':'application/json',Authorization:'Bearer '+bearer}, body:JSON.stringify({id:missingId})})).status, 200);
      await page.getByRole('button', {name:'Edit Removed by another client', exact:true}).click();
      await expect(page.getByText('Todo no longer exists. Refresh the list.', {exact:true})).toBeVisible();
      await page.getByRole('button', {name:'Refresh', exact:true}).click();
      await expect(page.getByText('No todos yet.', {exact:true})).toBeVisible();
      await page.getByRole('textbox', {name:'New todo title', exact:true}).fill('Persisted UI 🚀');
      await page.getByRole('button', {name:'Add todo', exact:true}).click();
      await expect(page.getByText('Created.', {exact:true})).toBeVisible();
      await page.getByRole('checkbox', {name:'Complete Persisted UI 🚀', exact:true}).check();
      await expect(page.getByText('Complete', {exact:true})).toBeVisible();
      await page.route('**/rpc/v1/todos/list', route => route.abort('failed'));
      await page.getByRole('button', {name:'Refresh', exact:true}).click();
      await expect(page.getByText('Connection failed. Refresh before retrying a write.', {exact:true})).toBeVisible();
      await expect(rows).toHaveCount(1);
      await page.unroute('**/rpc/v1/todos/list');
      await page.getByRole('button', {name:'Refresh', exact:true}).click();
      await expect(page.getByText('Ready.', {exact:true})).toBeVisible();
      let blocked;
      await page.route('**/rpc/v1/todos/create', async route => {
        // Commit the real write, but withhold its acknowledgement from Flux UI.
        assert.equal((await route.fetch()).status(), 200);
        blocked = route;
      });
      await page.getByRole('textbox', {name:'New todo title', exact:true}).fill('Interrupted draft');
      await page.getByRole('button', {name:'Add todo', exact:true}).click();
      await expect.poll(() => Boolean(blocked)).toBeTruthy();
      const beforeResume = creates;
      await page.evaluate(() => window.dispatchEvent(new Event('pagehide')));
      await expect(page.getByText('Request interrupted. Refresh or explicitly retry after resuming.', {exact:true})).toBeVisible();
      await page.evaluate(() => window.dispatchEvent(new Event('pageshow')));
      await blocked.abort();
      await page.unroute('**/rpc/v1/todos/create');
      await expect(page.getByRole('textbox', {name:'New todo title', exact:true})).toHaveValue('Interrupted draft');
      await page.getByRole('button', {name:'Refresh', exact:true}).click();
      await expect(page.getByText('Ready.', {exact:true})).toBeVisible();
      assert.equal(creates, beforeResume, 'resume must not automatically retry a write');
      await expect(rows).toHaveCount(2);
      await page.getByRole('button', {name:'Delete Interrupted draft', exact:true}).click();
      await page.getByRole('button', {name:'Confirm delete', exact:true}).click();
      await expect(rows).toHaveCount(1);
      await page.reload();
      await expect(page.getByRole('button',{name:'Sign in',exact:true})).toBeVisible();
      await expect(rows).toHaveCount(0);
      assert.deepEqual(await page.evaluate(() => [localStorage.length,sessionStorage.length]),[0,0]);
      await signIn();
      await expect(page.getByText('Persisted UI 🚀', {exact:true})).toBeVisible();
      await expect(page.getByText('Complete', {exact:true})).toBeVisible();
      console.log('PASS Flux UI: loading/empty/validation, duplicate prevention, Unicode escaping, CRUD, confirmation, typed error/retry, lifecycle interruption recovery and reload persistence');
    }
    assert(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), 'application overflows a narrow viewport');
    assert.deepEqual(errors, [], 'unexpected browser runtime errors');
  } finally { await browser.close(); }
})().catch(error => { console.error(error); process.exitCode = 1; });
