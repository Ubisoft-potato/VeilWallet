// Standalone disposable chains for genuine pool/verifier execution. No upstream.
const fs = require('node:fs'), path = require('node:path'), net = require('node:net');
const {spawn} = require('node:child_process');
const root = path.resolve(__dirname, '../..');
const directory = fs.mkdtempSync(path.join(root, '.build/ProtocolAcceptance/privacy-run-'));
const children = [];
function stop() { for (const child of children) child.kill('SIGTERM'); }
process.on('exit', stop);
for (const signal of ['SIGINT','SIGTERM']) process.on(signal, () => {stop(); process.exit(0)});
async function main() {
  const ports = {};
  for (const id of [1,56]) {
    const server=net.createServer();
    await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
    const port=server.address().port; await new Promise(resolve=>server.close(resolve));
    const child=spawn(process.env.VEIL_ANVIL || 'anvil',['--host','127.0.0.1','--port',String(port),'--chain-id',String(id),'--accounts','0','--silent','--number','20000000'],{stdio:'ignore',cwd:directory});
    children.push(child);
    let ready=false;
    for(let i=0;i<100;i++) {
      if(child.exitCode!==null) throw Error('Local privacy chain exited');
      try {
        const response=await fetch('http://127.0.0.1:'+port,{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({jsonrpc:'2.0',id:1,method:'eth_chainId',params:[]}),signal:AbortSignal.timeout(1000)});
        if((await response.json()).result==='0x'+id.toString(16)){ready=true;break}
      } catch {}
      await new Promise(resolve=>setTimeout(resolve,100));
    }
    if(!ready) throw Error('Local privacy chain startup timed out');
    ports[id]=port;
  }
  const file=path.join(directory,'ports.json');fs.writeFileSync(file,JSON.stringify(ports),{mode:0o600});
  console.log('VEIL_PROTOCOL_PORTS='+file);process.stdin.resume();
}
main().catch(()=>{stop();console.error('Local privacy chain initialization failed');process.exitCode=1});
