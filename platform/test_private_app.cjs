// Real account UI + two independent browser contexts + delivered stale callbacks.
const {chromium,expect}=require('@playwright/test');
const assert=require('node:assert/strict');
const base=process.argv[2], password='Private browser correct horse battery';
(async()=>{
  const browser=await chromium.launch({headless:true});
  const errors=[];
  try {
    const contexts=[await browser.newContext(),await browser.newContext()];
    const pages=await Promise.all(contexts.map(c=>c.newPage()));
    const tokens=new Map();
    for(const p of pages) {
      p.on('pageerror',e=>errors.push(e.message));
      p.on('response',async r=>{if(r.url().endsWith('/auth/login')&&r.status()===200)tokens.set(p,(await r.json()).token);});
      await p.goto(base);
    }
    const rows=p=>p.getByRole('group',{name:/^Todo /});
    const login=async(p,user)=>{
      await p.getByLabel('Username',{exact:true}).fill(user);
      await p.getByLabel('Password',{exact:true}).fill(password);
      await p.getByRole('button',{name:'Sign in',exact:true}).click();
      await expect(p.getByText('Ready.',{exact:true})).toBeVisible();
      await expect(p.getByText('Signed in as '+user,{exact:true})).toBeVisible();
    };
    const logout=async p=>{
      await p.getByRole('button',{name:'Sign out',exact:true}).click();
      await expect(p.getByText('Signed out.',{exact:true})).toBeVisible();
      await expect(rows(p)).toHaveCount(0);
    };
    const rpc=async(p,name,data={},token=tokens.get(p))=>p.evaluate(async({name,data,token})=>{
      const r=await fetch('/rpc/v1/'+name,{method:'POST',headers:{'Content-Type':'application/json',Authorization:'Bearer '+token},body:JSON.stringify(data)});
      return {status:r.status,body:await r.json(),cache:r.headers.get('Cache-Control')};
    },{name,data,token});
    const [a,b]=pages;
    for(const [p,user,title] of [[a,'browser_owner_a','Private A'],[b,'browser_owner_b','Private B']]) {
      await p.getByLabel('Username',{exact:true}).fill(user);
      await p.getByLabel('Password',{exact:true}).fill(password);
      await expect(p.getByLabel('Password',{exact:true})).toHaveAttribute('type','password');
      await p.getByRole('button',{name:'Create account',exact:true}).click();
      await expect(p.getByText('Account created. Sign in.',{exact:true})).toBeVisible();
      await expect(p.getByLabel('Password',{exact:true})).toHaveValue('');
      await login(p,user);
      await expect(rows(p)).toHaveCount(0);
      await p.getByLabel('New todo title',{exact:true}).fill(title);
      await p.getByRole('button',{name:'Add todo',exact:true}).click();
      await expect(p.getByText('Created.',{exact:true})).toBeVisible();
      await expect(rows(p)).toHaveCount(1);
    }
    const idA=(await rows(a).first().getAttribute('aria-label')).slice(5);
    const denied=await rpc(b,'todos/get',{id:idA,ownerId:'1'});
    assert.equal(denied.status,200); assert.deepEqual(denied.body,{todo:null}); assert.equal(denied.cache,'no-store');
    await expect(a.getByText('Private B',{exact:true})).toHaveCount(0);
    await expect(b.getByText('Private A',{exact:true})).toHaveCount(0);
    console.log('PASS two-context real registration/login, masked cleared passwords, owner isolation and direct foreign IDs');

    // Fetch A's genuine response before logout, but deliver it only after B loads.
    let held, response;
    await a.route('**/rpc/v1/todos/list',async route=>{
      if(held) return route.continue();
      held=route; response=await route.fetch();
    });
    await a.getByRole('button',{name:'Refresh',exact:true}).click();
    await expect.poll(()=>Boolean(response)).toBeTruthy();
    assert.equal(response.status(),200);
    await logout(a); await login(a,'browser_owner_b');
    await a.getByLabel('New todo title',{exact:true}).fill('B draft preserved');
    await held.fulfill({response}); await a.unroute('**/rpc/v1/todos/list');
    await a.waitForTimeout(150);
    await expect(rows(a)).toHaveCount(1);
    await expect(a.getByText('Private A',{exact:true})).toHaveCount(0);
    await expect(a.getByLabel('New todo title',{exact:true})).toHaveValue('B draft preserved');
    console.log('PASS delivered late user-A read cannot enter user-B state');

    await logout(a); await login(a,'browser_owner_a');
    let write, acknowledgement;
    await a.route('**/rpc/v1/todos/create',async route=>{write=route;acknowledgement=await route.fetch();});
    await a.getByLabel('New todo title',{exact:true}).fill('Late A write');
    await a.getByRole('button',{name:'Add todo',exact:true}).click();
    await expect.poll(()=>Boolean(acknowledgement)).toBeTruthy();
    assert.equal(acknowledgement.status(),200);
    await logout(a); await login(a,'browser_owner_b');
    await a.getByLabel('New todo title',{exact:true}).fill('B draft still preserved');
    await write.fulfill({response:acknowledgement}); await a.unroute('**/rpc/v1/todos/create');
    await a.waitForTimeout(150);
    await expect(rows(a)).toHaveCount(1);
    await expect(a.getByText('Late A write',{exact:true})).toHaveCount(0);
    await expect(a.getByLabel('New todo title',{exact:true})).toHaveValue('B draft still preserved');
    assert.deepEqual((await rpc(b,'todos/list',{afterId:null})).body.todos.map(t=>t.title),['Private B']);
    console.log('PASS committed late user-A write acknowledgement cannot mutate user-B rows or draft');

    const pendingToken=tokens.get(a); let logoutAttempts=0;
    await a.route('**/rpc/v1/auth/logout',route=>{logoutAttempts++;return route.abort('failed');});
    await a.getByRole('button',{name:'Sign out',exact:true}).click();
    await expect(a.getByText('Local data cleared. Server logout unconfirmed; retry sign out.',{exact:true})).toBeVisible();
    await expect(rows(a)).toHaveCount(0);
    assert.equal((await rpc(a,'auth/me',{},pendingToken)).status,200);
    await a.evaluate(()=>window.dispatchEvent(new Event('pageshow')));
    await a.waitForTimeout(100); assert.equal(logoutAttempts,1,'never automatically replay logout');
    await a.unroute('**/rpc/v1/auth/logout');
    await a.getByRole('button',{name:'Retry sign out',exact:true}).click();
    await expect(a.getByText('Signed out.',{exact:true})).toBeVisible();
    assert.equal((await rpc(a,'auth/me',{},pendingToken)).status,401);
    assert.equal((await rpc(b,'auth/me')).status,200,'scoped logout preserves second context session');
    console.log('PASS logout clears private data immediately, reports uncertainty, retries explicitly and revokes only its session');

    await login(a,'browser_owner_a');
    await expect(rows(a)).toHaveCount(2);
    assert.equal((await rpc(a,'auth/logoutall')).status,200);
    await a.getByRole('button',{name:'Refresh',exact:true}).click();
    await expect(a.getByText('Session expired or revoked. Sign in.',{exact:true})).toBeVisible();
    await expect(rows(a)).toHaveCount(0);
    await a.getByLabel('Username',{exact:true}).fill('browser_owner_a');
    await a.getByLabel('Password',{exact:true}).fill('incorrect password!');
    await a.getByRole('button',{name:'Sign in',exact:true}).click();
    await expect(a.getByText(/Invalid credentials/)).toBeVisible();
    await expect(a.getByLabel('Password',{exact:true})).toHaveValue('');
    for(const [i,p] of pages.entries()) {
      assert.deepEqual(await p.evaluate(()=>[localStorage.length,sessionStorage.length]),[0,0]);
      assert.deepEqual(await contexts[i].cookies(),[]);
    }
    assert.deepEqual(errors,[]);
    console.log('PASS real revocation clears UI, generic failed login clears password, no application credential storage or cookies');
  } finally {await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
