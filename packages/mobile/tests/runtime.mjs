import assert from 'node:assert/strict';
import {pathToFileURL} from 'node:url';
import path from 'node:path';
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
await import(pathToFileURL(path.resolve(process.argv[3])));
await tick();
resolveFirst({connected:false,connectionType:'none'});
event({connected:true,connectionType:'wifi'});
await tick();
globalThis.stopMobile();globalThis.stopMobile();
event({connected:false,connectionType:'none'});
await tick();
assert.deepEqual(globalThis.mobileResults.sort(),[
 'connected:True','selected:2','expected error:TypeError: Invalid confirmation','network:True',
].sort());
assert.equal(calls,2);assert.equal(removals,1);
console.log('PASS compiled Flux commands: typed errors, one-shot invocation, cancelled result suppression and listener disposal');
