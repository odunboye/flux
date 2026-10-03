// Scratch native app only. These are fixtures, never financial credentials.
let phase='open';
(async()=>{
  const assert=(condition)=>{if(!condition)throw Error('Native vault assertion failed');};
  const vault=await globalThis.IdrisCapacitorVault.open('https://vault.example.invalid');
  assert(vault!==null);
  const other=await globalThis.IdrisCapacitorVault.open('https://other.example.invalid');
  phase='read';
  const first=await vault.read(), separate=await other.read();
  const restored=first.value==='native-probe-fixture';
  assert(first.value===''||restored);
  if(separate.value==='')await other.write(separate.revision,'other-origin-fixture');
  phase='write';
  const saved=await vault.write(first.revision,'native-probe-fixture');
  assert(saved.revision!==first.revision);
  phase='clear';
  const cleared=await vault.clear();assert(cleared.value==='');
  for(const old of [first,saved]){
    let rejected=false;try{await vault.write(old.revision,'stale-fixture');}catch{rejected=true;}
    assert(rejected);
  }
  assert((await vault.read()).value==='');
  assert((await other.read()).value==='other-origin-fixture');
  await vault.write(cleared.revision,'native-probe-fixture');
  document.body.textContent=restored?'VAULT RESTORED PASS':'VAULT FIRST PASS';
})().catch(error=>{document.body.textContent='VAULT FAIL '+phase+' '+error.message;});
