// Export public verifier bytecode from the read-only, loopback-only fork pair.
const fs = require('node:fs'), path = require('node:path'), crypto = require('node:crypto');
const root = path.resolve(__dirname, '../..');
const directory = path.join(root, '.build/ProtocolAcceptance');
const {JsonRpcProvider,Contract} = require(path.join(directory,'node_modules/ethers'));
const pools = {
  1:['0x12D66f87A04A9E220743712cE6d9bB1B5616B8Fc','0x47CE0C6eD5B0Ce3d3A51fdb1C52DC66a7c3c2936','0x910Cbd523D972eb0a6f4cAe4618aD62622b39DbF','0xA160cdAB225685dA1d56aa342Ad8841c3b53f291'],
  56:['0x84443CFd09A48AF6eF360C6976C5392aC5023a1F','0xd47438C816c9E7f2E2888E060936a499Af9582b3','0x330bdFADE01eE9bF63C209Ee33102DD334618e0a','0x1E34A77868E19A6647b1f2F47B51ed72dEDE95DD']
};
async function main() {
  if(!process.env.VEIL_PROTOCOL_PORTS) throw Error('Missing local fork configuration');
  const ports=JSON.parse(fs.readFileSync(process.env.VEIL_PROTOCOL_PORTS));
  fs.mkdirSync(path.join(directory,'contracts'),{recursive:true});
  for(const id of [1,56]) {
    if(!Number.isInteger(ports[id]) || ports[id]<1 || ports[id]>65535) throw Error('Invalid local fork port');
    const provider=new JsonRpcProvider('http://127.0.0.1:'+ports[id]);
    try {
      await provider.send('anvil_nodeInfo',[]);
      if((await provider.getNetwork()).chainId!==BigInt(id)) throw Error('Wrong fork chain');
      let fixture;
      for(const pool of pools[id]) {
        const address=await new Contract(pool,['function verifier() view returns(address)'],provider).verifier();
        const code=await provider.getCode(address);
        if(code==='0x') throw Error('Missing real verifier');
        const sha256=crypto.createHash('sha256').update(Buffer.from(code.slice(2),'hex')).digest('hex');
        if(fixture && fixture.sha256!==sha256) throw Error('Pool verifier code differs within chain');
        fixture={chainID:id,address,code,sha256,source:'Read-only local fork of catalog Classic pools'};
      }
      fs.writeFileSync(path.join(directory,'contracts/verifier-code'+(id===1?'':'-56')+'.json'),JSON.stringify(fixture),{mode:0o600});
      console.log('Exported public verifier for all four pools on chain '+id);
    } finally { provider.destroy(); }
  }
}
main().catch(()=>{console.error('Verifier export failed; no secrets logged');process.exitCode=1});
