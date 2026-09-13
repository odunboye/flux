import {test} from 'node:test';
import assert from 'node:assert/strict';
import {createRpcTransport, validApiOrigin} from '../tooling/rpc.mjs';
const origin='https://api.example.test';
const headers=JSON.stringify({'Content-Type':'application/json',Authorization:'Bearer fixture'});
const tick=()=>new Promise(resolve=>setImmediate(resolve));
function request(transport, url=origin+'/rpc/v1/auth/login', limit=128, timeout=1000) {
 let stop;
 const result=new Promise(resolve=>{stop=transport.request('POST',url,headers,'{}',timeout,limit,(status,body)=>resolve({status,body}));});
 return {result,stop};
}

test('HTTPS configuration, exact origin/path and no insecure fallback', async()=>{
 for(const value of ['',undefined,'http://localhost','https://api.example.test/','https://u:p@api.example.test','https://api.example.test?q=1'])
  assert.equal(validApiOrigin(value),false);
 let calls=0;const transport=createRpcTransport(origin,()=>{calls++;return new Response('{}');});
 for(const url of ['https://evil.test/rpc/v1/auth/login',origin+'/other',origin+'/rpc/v1/auth/login?q=token'])
  assert.equal((await request(transport,url).result).status,-1);
 assert.equal(calls,0);
});

test('credentials omitted, redirects rejected, caching disabled and no retries', async()=>{
 let calls=0;
 const transport=createRpcTransport(origin,async(url,options)=>{
  calls++;assert.equal(options.credentials,'omit');assert.equal(options.redirect,'error');
  assert.equal(options.cache,'no-store');assert.equal(options.mode,'cors');
  assert.equal(options.headers.get('authorization'),'Bearer fixture');throw Error('connection lost');
 });
 assert.equal((await request(transport).result).status,-1);await tick();assert.equal(calls,1);
});

test('streamed body is bounded even without Content-Length', async()=>{
 const transport=createRpcTransport(origin,async()=>new Response(new ReadableStream({start(c){c.enqueue(new Uint8Array(100));c.enqueue(new Uint8Array(100));c.close();}})));
 assert.equal((await request(transport).result).status,-3);
 const advertised=createRpcTransport(origin,async()=>new Response('{}',{headers:{'Content-Length':'99999'}}));
 assert.equal((await request(advertised).result).status,-3);
});

test('HTTP errors remain readable, timeout settles once and cancellation drops late results', async()=>{
 const denied=createRpcTransport(origin,async()=>new Response('{"error":{}}',{status:401}));
 assert.equal((await request(denied).result).status,401);
 let resolve,calls=0,deliveries=0;
 const delayed=createRpcTransport(origin,()=>{calls++;return new Promise(r=>{resolve=r;});});
 const timed=request(delayed,undefined,128,10);assert.equal((await timed.result).status,-2);
 resolve(new Response('{}'));await tick();assert.equal(calls,1);
 const stop=delayed.request('POST',origin+'/rpc/v1/auth/login',headers,'{}',1000,128,()=>{deliveries++;});
 await tick();stop.cancel();stop.cancel();resolve(new Response('{}'));await tick();
 assert.equal(deliveries,0);assert.equal(calls,2);
});
