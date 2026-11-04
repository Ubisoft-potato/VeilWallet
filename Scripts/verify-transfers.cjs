// Developer-only independent vectors. All secrets are public test material.
const fs = require('node:fs');
const path = require('node:path');
const { createRequire } = require('node:module');
const root = path.resolve(__dirname, '..');
const req = createRequire(path.join(root, '.build/verification/package.json'));
const btc = req('bitcoinjs-lib'); const secp = req('tiny-secp256k1'); btc.initEccLib(secp);
const { HDKey } = req('@scure/bip32'); const { mnemonicToSeedSync } = req('@scure/bip39');
const { base58, base58check, bech32 } = req('@scure/base');
const { sha256 } = req('@noble/hashes/sha256'); const { keccak_256, sha3_256 } = req('@noble/hashes/sha3');
const { ed25519 } = req('@noble/curves/ed25519'); const { Interface, SigningKey } = req('ethers');
const hex = bytes => Buffer.from(bytes).toString('hex');
const join = (...args) => Buffer.concat(args.map(x => Buffer.from(x)));
const le64 = n => { const b=Buffer.alloc(8); b.writeBigUInt64LE(BigInt(n)); return b; };
const phrase = 'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';
const hd = HDKey.fromMasterSeed(mnemonicToSeedSync(phrase));
const b58check = base58check(sha256);
const ltc = { ...btc.networks.bitcoin, bech32:'ltc', pubKeyHash:0x30, scriptHash:0x32, wif:0xb0 };
const cases = [];
for (const [family,network,coin] of [['bitcoin',btc.networks.bitcoin,0],['litecoin',ltc,2]]) {
 for (const [variant,purpose] of [['legacy',44],['nested',49],['segwit',84],['taproot',86],...(family==='litecoin'?[['nested-compat',49]]:[])]) {
  const secret = hd.derive(`m/${purpose}'/${coin}'/0'/0/0`).privateKey;
  const pub = Buffer.from(secp.pointFromScalar(secret,true));
  const targetSecret = hd.derive(`m/${purpose}'/${coin}'/0'/0/1`).privateKey;
  const targetPub = Buffer.from(secp.pointFromScalar(targetSecret,true));
  const payment = p => variant==='legacy'?btc.payments.p2pkh({pubkey:p,network}):variant==='segwit'?btc.payments.p2wpkh({pubkey:p,network}):variant==='taproot'?btc.payments.p2tr({internalPubkey:p.subarray(1),network}):btc.payments.p2sh({redeem:btc.payments.p2wpkh({pubkey:p,network}),network});
  const sender=payment(pub); const recipient=payment(targetPub);
  let address=sender.address;
  if(variant==='nested-compat') address=b58check.encode(join([5],sender.hash));
  const prev=new btc.Transaction(); prev.version=2; prev.addInput(Buffer.alloc(32),0xffffffff,0xffffffff,Buffer.from([1,1])); prev.addOutput(sender.output,2000000);
  const tx=new btc.Transaction(); tx.version=2; tx.addInput(prev.getHash(),0,0xffffffff); tx.addOutput(recipient.output,1000000); tx.addOutput(sender.output,990000);
  const unsigned=tx.toHex(); const hashes=[sender.output], amounts=[2000000];
  if(variant==='legacy') {
   const sig=btc.script.signature.encode(Buffer.from(secp.sign(tx.hashForSignature(0,sender.output,1),secret)),1);
   tx.setInputScript(0,btc.script.compile([sig,pub]));
  } else if(variant==='taproot') {
   const normalized=pub[0]===3?secp.privateNegate(secret):secret;
   const tweaked=secp.privateAdd(normalized,btc.crypto.taggedHash('TapTweak',pub.subarray(1)));
   tx.setWitness(0,[Buffer.from(secp.signSchnorr(tx.hashForWitnessV1(0,hashes,amounts,0),tweaked,Buffer.alloc(32)))]);
  } else {
   const scriptCode=btc.payments.p2pkh({pubkey:pub,network}).output;
   const sig=btc.script.signature.encode(Buffer.from(secp.sign(tx.hashForWitnessV0(0,scriptCode,2000000,1),secret)),1);
   if(variant.startsWith('nested')) tx.setInputScript(0,btc.script.compile([sender.redeem.output]));
   tx.setWitness(0,[sig,pub]);
  }
  cases.push({profile:family==='bitcoin'?'btc.'+variant:'ltc.'+variant.replace('nested-compat','nested.compat'),material:hex(secret),payload:{from:address,to:recipient.address,amount:'1000000',fee:'10000',change:'990000',inputs:[{txid:prev.getId(),index:0,value:'2000000',previous:prev.toHex()}]},unsigned,signed:tx.toHex(),hash:tx.getId()});
 }
}
const seed=Buffer.alloc(32,1); const publicKey=Buffer.from(ed25519.getPublicKey(seed)); const receiver=Buffer.from(ed25519.getPublicKey(Buffer.alloc(32,2)));
const blockhash=Buffer.alloc(32,0x42); const transferData=join([2,0,0,0],le64(1000000));
const solMessage=join([1,0,1,3],publicKey,receiver,Buffer.alloc(32),blockhash,[1,2,2,0,1,12],transferData);
const solSignature=Buffer.from(ed25519.sign(solMessage,seed));
cases.push({profile:'solana',material:hex(seed),payload:{from:base58.encode(publicKey),to:base58.encode(receiver),amount:'1000000',blockHash:base58.encode(blockhash)},unsigned:hex(solMessage),signed:join([1],solSignature,solMessage).toString('base64'),hash:base58.encode(solSignature)});
const aptosSender=Buffer.from(sha3_256(join(publicKey,[0]))); const aptosRecipient=Buffer.from(sha3_256(join(receiver,[0])));
const text = s => join([Buffer.byteLength(s)],Buffer.from(s)); const core=Buffer.alloc(32);core[31]=1;
const aptosRaw=join(aptosSender,le64(7),[2],core,text('aptos_account'),text('transfer'),[0,2,32],aptosRecipient,[8],le64(1000000),le64(2000),le64(100),le64(1900000000),[1]);
const aptosSignature=ed25519.sign(join(sha3_256(Buffer.from('APTOS::RawTransaction')),aptosRaw),seed);
const aptosSigned=join(aptosRaw,[0,32],publicKey,[64],aptosSignature);
cases.push({profile:'aptos',material:hex(seed),payload:{from:'0x'+hex(aptosSender),to:'0x'+hex(aptosRecipient),amount:'1000000',nonce:'7',maxGas:'2000',gasPrice:'100',expiration:'1900000000',publicKey:hex(publicKey)},unsigned:hex(aptosRaw),signed:hex(aptosSigned),hash:'0x'+hex(sha3_256(join(sha3_256(Buffer.from('APTOS::Transaction')),[0],aptosSigned)))});
const node=hd.derive("m/44'/128'/0'/0/0");
const little = bytes => BigInt('0x'+hex(Buffer.from(bytes).reverse()));
const scalarOrder=2n**252n+27742317777372353535851937790883648493n;
const scalarBytes = n => Buffer.from(n.toString(16).padStart(64,'0'),'hex').reverse();
const spend=scalarBytes(little(keccak_256(node.privateKey))%scalarOrder);
const view=scalarBytes(little(keccak_256(spend))%scalarOrder);
const xmrPublic=n=>Buffer.from(ed25519.ExtendedPoint.BASE.multiply(little(n)).toRawBytes());
const xmrRaw=join([18],xmrPublic(spend),xmrPublic(view)); const checked=join(xmrRaw,keccak_256(xmrRaw).subarray(0,4));
let xmrAddress='';const lengths=[0,2,3,5,6,7,9,10,11];
for(let i=0;i<checked.length;i+=8){const b=checked.subarray(i,i+8);xmrAddress+=base58.encode(b).padStart(lengths[b.length],'1');}
// Independent protobuf encoding of Cosmos SIGN_MODE_DIRECT and Injective's key type.
const vint=n=>{ let x=BigInt(n),r=[]; do { let b=Number(x&127n); x>>=7n; r.push(b|(x?128:0)); } while(x); return Buffer.from(r); };
const pb=(i,b)=>join(vint(i*8+2),vint(b.length),b);
const pi=(i,n)=>BigInt(n)===0n?Buffer.alloc(0):join(vint(i*8),vint(n));
const ps=(i,s)=>s?pb(i,Buffer.from(s)):Buffer.alloc(0);
const any=(name,bytes)=>join(ps(1,name),pb(2,bytes));
const cosmosKey=Buffer.alloc(32,1), cosmosPub=Buffer.from(secp.pointFromScalar(cosmosKey,true));
for(const eth of [false,true]) {
 const profile=eth?'injective':'cosmos', hrp=eth?'inj':'cosmos', chain=eth?'injective-1':'cosmoshub-4', denom=eth?'inj':'uatom';
 const address=bech32.encode(hrp,bech32.toWords(eth?keccak_256(secp.pointFromScalar(cosmosKey,false).slice(1)).slice(12):btc.crypto.hash160(cosmosPub)));
 const recipient=bech32.encode(hrp,bech32.toWords(Buffer.alloc(20,2)));
 const coin=(amount)=>join(ps(1,denom),ps(2,amount));
 const msg=join(ps(1,address),ps(2,recipient),pb(3,coin('1000000')));
 const body=join(pb(1,any('/cosmos.bank.v1beta1.MsgSend',msg)),ps(2,'public test memo'),pi(3,123456));
 const pub=any(eth?'/injective.crypto.v1beta1.ethsecp256k1.PubKey':'/cosmos.crypto.secp256k1.PubKey',pb(1,cosmosPub));
 const signer=join(pb(1,pub),pb(2,pb(1,pi(1,1))),pi(3,7));
 const auth=join(pb(1,signer),pb(2,join(pb(1,coin('5000')),pi(2,200000))));
 const doc=join(pb(1,body),pb(2,auth),ps(3,chain),pi(4,42));
 const digest=eth?keccak_256(doc):sha256(doc);
 const sig=eth?Buffer.from(new SigningKey('0x'+hex(cosmosKey)).sign('0x'+hex(digest)).serialized.slice(2),'hex'):Buffer.from(secp.sign(digest,cosmosKey));
 if(eth) sig[64]-=27;
 const raw=join(pb(1,body),pb(2,auth),pb(3,sig));
 cases.push({profile,material:hex(cosmosKey),payload:{from:address,to:recipient,amount:'1000000',fee:'5000',maxGas:'200000',nonce:'7',accountNumber:'42',chainIdentifier:chain,denomination:denom,expiration:'123456',publicKey:hex(cosmosPub),memo:'public test memo'},unsigned:hex(doc),signed:raw.toString('base64'),hash:hex(sha256(raw)).toUpperCase()});
}
const tronFrom=join([0x41],keccak_256(secp.pointFromScalar(cosmosKey,false).slice(1)).slice(12)), tronTo=join([0x41],Buffer.alloc(20,2));
const tronTransfer=join(pb(1,tronFrom),pb(2,tronTo),pi(3,1000000));
const tronContract=join(pi(1,1),pb(2,any('type.googleapis.com/protocol.TransferContract',tronTransfer)));
const tronRaw=join(pb(1,Buffer.from('00ab','hex')),pb(4,Buffer.alloc(8,1)),pi(8,1700000180000),pb(11,tronContract),pi(14,1700000000000));
const tronDigest=sha256(tronRaw), tronSignature=Buffer.from(new SigningKey('0x'+hex(cosmosKey)).sign('0x'+hex(tronDigest)).serialized.slice(2),'hex'); tronSignature[64]-=27;
const tronSigned=join(pb(1,tronRaw),pb(2,tronSignature));
cases.push({profile:'tron',material:hex(cosmosKey),payload:{from:b58check.encode(tronFrom),to:b58check.encode(tronTo),amount:'1000000',refBytes:'00ab',refHash:'0101010101010101',timestamp:'1700000000000',expiration:'1700000180000'},unsigned:hex(tronRaw),signed:hex(tronSigned),hash:hex(tronDigest)});
// Independent TriggerSmartContract protobuf, including zero call_value and fee_limit.
const tronTarget=b58check.decode('TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t'), tronSpender=b58check.decode('TNJVzGqKBWkJxJB5XYSqGAwUTV15U24pPq');
const tronData=Buffer.from(new Interface(['function approve(address,uint256)']).encodeFunctionData('approve',['0x'+hex(tronSpender.slice(1)),1000000]).slice(2),'hex');
const trigger=join(pb(1,tronFrom),pb(2,tronTarget),pb(4,tronData));
const triggerRaw=join(pb(1,Buffer.from('00ab','hex')),pb(4,Buffer.alloc(8,1)),pi(8,1700000180000),pb(11,join(pi(1,31),pb(2,any('type.googleapis.com/protocol.TriggerSmartContract',trigger)))),pi(14,1700000000000),pi(18,100000000));
const triggerHash=sha256(triggerRaw), triggerSig=Buffer.from(new SigningKey('0x'+hex(cosmosKey)).sign('0x'+hex(triggerHash)).serialized.slice(2),'hex'); triggerSig[64]-=27;
cases.push({profile:'tron',material:hex(cosmosKey),payload:{from:b58check.encode(tronFrom),to:b58check.encode(tronTarget),amount:'0',contractData:hex(tronData),feeLimit:'100000000',refBytes:'00ab',refHash:'0101010101010101',timestamp:'1700000000000',expiration:'1700000180000'},unsigned:hex(triggerRaw),signed:hex(join(pb(1,triggerRaw),pb(2,triggerSig))),hash:hex(triggerHash)});
const tronWrapped=b58check.decode('TNUC9Qb1rRpS5CbWLmNMxXBjyFoydXjWFR');
const swapData=Buffer.from(new Interface(['function swapExactETHForTokens(uint256,address[],address,uint256)']).encodeFunctionData('swapExactETHForTokens',[250000,['0x'+hex(tronWrapped.slice(1)),'0x'+hex(tronTarget.slice(1))],'0x'+hex(tronFrom.slice(1)),1700000300]).slice(2),'hex');
const swapTrigger=join(pb(1,tronFrom),pb(2,tronSpender),pi(3,1000000),pb(4,swapData));
const swapRaw=join(pb(1,Buffer.from('00ab','hex')),pb(4,Buffer.alloc(8,1)),pi(8,1700000180000),pb(11,join(pi(1,31),pb(2,any('type.googleapis.com/protocol.TriggerSmartContract',swapTrigger)))),pi(14,1700000000000),pi(18,100000000));
const swapHash=sha256(swapRaw), swapSig=Buffer.from(new SigningKey('0x'+hex(cosmosKey)).sign('0x'+hex(swapHash)).serialized.slice(2),'hex'); swapSig[64]-=27;
cases.push({profile:'tron',material:hex(cosmosKey),payload:{from:b58check.encode(tronFrom),to:b58check.encode(tronSpender),amount:'1000000',contractData:hex(swapData),feeLimit:'100000000',refBytes:'00ab',refHash:'0101010101010101',timestamp:'1700000000000',expiration:'1700000180000'},unsigned:hex(swapRaw),signed:hex(join(pb(1,swapRaw),pb(2,swapSig))),hash:hex(swapHash)});
for (const item of cases) item.payload={from:'',to:'',amount:'',fee:'0',change:'0',blockHash:'',nonce:'0',maxGas:'0',gasPrice:'0',expiration:'0',refBytes:'',refHash:'',timestamp:'0',publicKey:'',inputs:[],chainIdentifier:'',denomination:'',accountNumber:'0',memo:'',...item.payload};
const abi=[];
for(const [signature,args] of [['f(address,uint256,bool)',['0x000000000000000000000000000000000000dEaD','123456789012345678901234567890','true']],['f(bytes,string,bytes4)',['0x000102ff','隐私钱包','0xdeadbeef']],['f(uint256[],address[])',['["0","1","123456789"]','["0x000000000000000000000000000000000000dEaD"]']],['f()',[]]]){
 const types=signature.slice(signature.indexOf('(')+1,-1).split(',').filter(Boolean);const parsed=args.map((a,i)=>types[i].endsWith('[]')?JSON.parse(a):types[i]==='bool'?a==='true':a);
 abi.push({signature,args,encoded:new Interface(['function '+signature]).encodeFunctionData('f',parsed)});
}
const A='0x1111111111111111111111111111111111111111', B='0x2222222222222222222222222222222222222222', Z='0x0000000000000000000000000000000000000000';
const js=JSON.stringify;
const abiCases=[
 ['verifyProof(bytes,uint256[6])',['0x'+'01'.repeat(256),js(['1','2','57005','0','0','0'])]],
 ['f(bytes[2],uint256[2][2])',[js(['0x01','0x0203']),js([js(['1','2']),js(['3','4'])])]],
 ['bridge(address,uint256,bytes32,uint256,uint256,uint256,uint256)',[A,'10000000','0x'+'00'.repeat(12)+B.slice(2),'3','0','0','50']],
 ['sendToken((uint32,bytes32,uint256,uint256,bytes,bytes,bytes),(uint256,uint256),address)',[js(['30102','0x'+'00'.repeat(12)+B.slice(2),'10000000','9950000','0x','0x','0x']),js(['123456','0']),A]],
 ['withdraw(bytes,bytes32,bytes32,address,address,uint256,uint256)',['0x'+'01'.repeat(256),'0x'+'02'.repeat(32),'0x'+'03'.repeat(32),A,Z,'0','0']],
 ['f((address,uint256),bytes[])',[js([A,'123']),js(['0x01','0x','0x010203'])]],
 ['f((address,bool)[],int24,int256)',[js([js([A,'true']),js([B,'false'])]),'-8388608',String(-(1n<<255n))]],
 ['f((bytes,address,uint256,uint256,uint256))',[js(['0x'+hex(join(Buffer.from(A.slice(2),'hex'),[0,11,184],Buffer.from(B.slice(2),'hex'))),A,'1900000000','1000','990'])]],
 ['f(((address,address,uint24,int24,address),bool,uint128,uint128,uint256,bytes),bytes[])',[js([js([Z,B,'3000','60',Z]),'true','1000','990','0','0x']),js(['0x010203','0x'])]],
 ['multicall(uint256,bytes[])',['1900000000',js(['0x12345678','0x0102030405'])]],
 ['f((address,uint256,(bytes,bool)[])[])',[js([js([A,'42',js([js(['0x0102','true']),js(['0x','false'])])])])]],
 ['f(bytes[],uint256[])',[js([]),js([])]]
];
function parseArgument(type,value){if(type.baseType==='array')return JSON.parse(value).map(v=>parseArgument(type.arrayChildren,v));if(type.baseType==='tuple')return JSON.parse(value).map((v,i)=>parseArgument(type.components[i],v));return type.type==='bool'?value==='true':value;}
for(const[signature,args]of abiCases){const iface=new Interface(['function '+signature]), name=signature.slice(0,signature.indexOf('(')), fn=iface.getFunction(name);const parsed=args.map((v,i)=>parseArgument(fn.inputs[i],v));abi.push({signature,args,encoded:iface.encodeFunctionData(name,parsed)});}
const moneroWords=fs.readFileSync(path.join(root,'Native/ChainCore/monero-english.txt'),'utf8').trim().split(/\s+/), nativeSeedWords=[];
for(let i=0;i<8;i++) { const x=spend.readUInt32LE(i*4), a=x%1626, b=(Math.floor(x/1626)+a)%1626, c=(Math.floor(x/(1626*1626))+b)%1626; nativeSeedWords.push(moneroWords[a],moneroWords[b],moneroWords[c]); }
nativeSeedWords.push(nativeSeedWords[req('node:zlib').crc32(Buffer.from(nativeSeedWords.map(w=>w.slice(0,3)).join('')))%24]);
fs.writeFileSync(path.join(root,'Tests/WalletCoreTests/Fixtures/transfer-reference.json'),JSON.stringify({source:'Independent bitcoinjs-lib / tiny-secp256k1 / noble / scure / ethers; public test data only',cases,monero:{phrase,path:"m/44'/128'/0'/0/0",address:xmrAddress,spend:hex(spend),view:hex(view),nativeSeed:nativeSeedWords.join(' ')},abi},null,2)+'\n');
console.log('Wrote independent UTXO / Solana / Aptos / Monero / ABI fixtures; no keys or addresses logged.');
