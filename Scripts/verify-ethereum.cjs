// Optional independent development verification. Never included in the app.
// npm install --prefix .build/verification ethers@6.15.0 --ignore-scripts --no-audit
const { Wallet, HDNodeWallet } = require('../.build/verification/node_modules/ethers');
(async () => {
  const wallet = new Wallet('0x' + '0'.repeat(63) + '1');
  const raw = await wallet.signTransaction({type:2,chainId:1,nonce:0,maxPriorityFeePerGas:1000000000n,
    maxFeePerGas:20000000000n,gasLimit:21000,to:'0x000000000000000000000000000000000000dEaD',value:1n});
  const legacy = await wallet.signTransaction({type:0,chainId:1,nonce:0,gasPrice:20000000000n,gasLimit:21000,to:'0x000000000000000000000000000000000000dEaD',value:1n});
  const master = HDNodeWallet.fromSeed('0x000102030405060708090a0b0c0d0e0f');
  console.log(JSON.stringify({legacy:legacy.slice(2),raw:raw.slice(2), master:master.privateKey.slice(2), child:master.derivePath("m/0'").privateKey.slice(2), chainCode:master.derivePath("m/0'").chainCode.slice(2)},null,2));
})();
