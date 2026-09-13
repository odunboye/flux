import assert from 'node:assert/strict';
import {pathToFileURL} from 'node:url';
import path from 'node:path';
import {randomUUID,webcrypto} from 'node:crypto';
const library=path.resolve(process.argv[2]);
const {createBridge}=await import(pathToFileURL(path.join(library,'js/bridge.mjs')));
const tick=()=>new Promise(resolve=>setImmediate(resolve));
let resolveFirst,event,calls=0,removals=0;
globalThis.mobileResults=[];
globalThis.IdrisCapacitor=createBridge({
 Network:{
  getStatus(){calls++;return calls===1?new Promise(r=>{resolveFirst=r;}):{connected:true,connectionType:'wifi'};},
  addListener(_,cb){event=cb;return {remove(){removals++;}};},
 },
 ActionSheet:{showActions(options){assert.deepEqual(options.options.map(x=>x.title),['','Share','£ / ₦']);return {index:2};}},
 Dialog:{confirm(){return {}; }},
});
const {createNativeVault}=await import(pathToFileURL(path.join(library,'js/vault.mjs')));
let vaultSlot={revision:randomUUID(),value:''},writes=0;
globalThis.IdrisCapacitorVault=createNativeVault({isLoggingEnabled:false,isNativePlatform:()=>true,getPlatform:()=> 'ios',isPluginAvailable:()=>true},{
 read:async({scope})=>{assert.match(scope,/^[a-f0-9]{64}$/);return vaultSlot;},
 write:async({revision,value})=>{assert.equal(revision,vaultSlot.revision);writes++;return vaultSlot={revision:randomUUID(),value};},
 clear:async()=>{return vaultSlot={revision:randomUUID(),value:''};}
},webcrypto);
await import(pathToFileURL(path.resolve(process.argv[3])));
await tick();
resolveFirst({connected:false,connectionType:'none'});
event({connected:true,connectionType:'wifi'});
await tick();
globalThis.stopMobile();globalThis.stopMobile();
event({connected:false,connectionType:'none'});
await tick();
for(let i=0;i<50&&!globalThis.mobileResults.includes('vault ffi:passed');i++)await new Promise(resolve=>setTimeout(resolve,20));
assert.equal(writes,1);
assert.deepEqual(globalThis.mobileResults.sort(),[
 'connected:True','selected:2','expected error:TypeError: Invalid confirmation','network:True',
 'vault ffi:passed','vault codec:passed','vault metadata:rejected',
].sort());
assert.equal(calls,2);assert.equal(removals,1);
console.log('PASS compiled Flux commands: typed errors, one-shot invocation, cancelled result suppression and listener disposal');
