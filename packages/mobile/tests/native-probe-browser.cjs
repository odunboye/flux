// Minimal page-target CDP: old Android WebViews do not implement browser-context
// downloads, so full Playwright connectOverCDP initialization is inappropriate.
(async()=>{
 const targets=await (await fetch('http://127.0.0.1:'+process.argv[2]+'/json/list')).json();
 const target=targets.find(t=>t.type==='page'&&t.url.startsWith('https://localhost'));
 if(!target)throw Error('Owned WebView page not found');
 const socket=new WebSocket(target.webSocketDebuggerUrl);let sequence=0;
 const pending=new Map(),seen=[];
 socket.addEventListener('message',event=>{
  const message=JSON.parse(event.data),task=pending.get(message.id);
  seen.push(message.method||('reply:'+message.id));
  if(task){pending.delete(message.id);clearTimeout(task.timer);message.error?task.reject(Error('CDP evaluation failed')):task.resolve(message.result);}
 });
 await new Promise((resolve,reject)=>{socket.addEventListener('open',resolve,{once:true});socket.addEventListener('error',reject,{once:true});});
 const evaluate=expression=>new Promise((resolve,reject)=>{
  const id=++sequence,timer=setTimeout(()=>{pending.delete(id);reject(Error('Native probe evaluation timed out; protocol events: '+seen.join(',')));},15000);
  pending.set(id,{resolve,reject,timer});
  socket.send(JSON.stringify({id,method:'Runtime.evaluate',params:{expression,awaitPromise:true,returnByValue:true}}));
 }).then(result=>{if(result.exceptionDetails)throw Error('Native probe expression failed');return result.result.value;});
 try{
  if(process.argv[3]==='locked'){
   const denied=await evaluate("(async()=>{try{await (await globalThis.IdrisCapacitorVault.open('https://vault.example.invalid')).read();return false;}catch{return true;}})()");
   if(!denied)throw Error('Locked device returned a vault value');
  }else{
   let text='';
   for(let i=0;i<100;i++){
    text=await evaluate('document.body.textContent');
    if(text.includes(process.argv[3]))return;
    if(text.includes('VAULT FAIL'))break;
    await new Promise(resolve=>setTimeout(resolve,200));
   }
   throw Error('Unexpected native probe result: '+text);
  }
 }finally{socket.close();for(const task of pending.values())clearTimeout(task.timer);}
})().catch(error=>{console.error(error.message);process.exitCode=1;});
