// Independent, offline public test vectors. These libraries are NEVER shipped.
const fs=require('fs');const crypto=require('crypto');
const {HDKey}=require('../.build/verification/node_modules/@scure/bip32');
const {mnemonicToSeedSync}=require('../.build/verification/node_modules/@scure/bip39');
const {base58,bech32,bech32m}=require('../.build/verification/node_modules/@scure/base');
const {ed25519}=require('../.build/verification/node_modules/@noble/curves/ed25519');
const {secp256k1}=require('../.build/verification/node_modules/@noble/curves/secp256k1');
const {sha256}=require('../.build/verification/node_modules/@noble/hashes/sha256');
const {ripemd160}=require('../.build/verification/node_modules/@noble/hashes/ripemd160');
const {sha3_256,keccak_256}=require('../.build/verification/node_modules/@noble/hashes/sha3');
const {blake2b}=require('../.build/verification/node_modules/@noble/hashes/blake2b');
const {blake3}=require('../.build/verification/node_modules/@noble/hashes/blake3');
const stark=require('../.build/verification/node_modules/@scure/starknet');
const btc=require('../.build/verification/node_modules/bitcoinjs-lib');
btc.initEccLib(require('../.build/verification/node_modules/tiny-secp256k1'));
const ton=require('../.build/verification/node_modules/@ton/ton');
const cardano=require('../.build/verification/node_modules/@emurgo/cardano-serialization-lib-nodejs');
const phrase='abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';
const seed=mnemonicToSeedSync(phrase);const root=HDKey.fromMasterSeed(seed);
const secp=(path)=>Buffer.from(root.derive(path).privateKey);
function slip(path){let hash=crypto.createHmac('sha512','ed25519 seed').update(seed).digest();for(const part of path.split('/').slice(1)){if(!part.endsWith("'"))throw Error('unhardened');const num=Buffer.alloc(4);num.writeUInt32BE(Number(part.slice(0,-1))+0x80000000);hash=crypto.createHmac('sha512',hash.subarray(32)).update(Buffer.concat([Buffer.from([0]),hash.subarray(0,32),num])).digest();}return hash.subarray(0,32);}
const checksum=(p)=>Buffer.concat([p,Buffer.from(sha256(sha256(p))).subarray(0,4)]);
const accounts={};const add=(id,path,address)=>accounts[id]={path,address};
for(const [id,path,kind] of [ ['btc.segwit',"m/84'/0'/0'/0/0",'p2wpkh'], ['btc.legacy',"m/44'/0'/0'/0/0",'p2pkh'], ['btc.nested',"m/49'/0'/0'/0/0",'nested'], ['btc.taproot',"m/86'/0'/0'/0/0",'p2tr'] ]){
 const pubkey=Buffer.from(secp256k1.getPublicKey(secp(path),true));
 const payment=kind==='nested'?btc.payments.p2sh({redeem:btc.payments.p2wpkh({pubkey})}):kind==='p2tr'?btc.payments.p2tr({internalPubkey:pubkey.subarray(1)}):btc.payments[kind]({pubkey});add(id,path,payment.address);
}
for(const [id,path] of [['solana',"m/44'/501'/0'/0'"],['solana.legacy',"m/44'/501'/0'"]]) add(id,path,base58.encode(ed25519.getPublicKey(slip(path))));
let path="m/44'/195'/0'/0/0";let pub=secp256k1.getPublicKey(secp(path),false);add('tron',path,base58.encode(checksum(Buffer.concat([Buffer.from([0x41]),Buffer.from(keccak_256(pub.subarray(1))).subarray(12)]))));
path="m/44'/784'/0'/0'/0'";add('sui',path,'0x'+Buffer.from(blake2b(Buffer.concat([Buffer.from([0]),Buffer.from(ed25519.getPublicKey(slip(path)))]),{dkLen:32})).toString('hex'));
path="m/44'/637'/0'/0'/0'";add('aptos',path,'0x'+Buffer.from(sha3_256(Buffer.concat([Buffer.from(ed25519.getPublicKey(slip(path))),Buffer.from([0])]))).toString('hex'));
path="m/44'/607'/0'";pub=Buffer.from(ed25519.getPublicKey(slip(path)));
add('ton.v4',path,ton.WalletContractV4.create({workchain:0,publicKey:pub}).address.toString({bounceable:false}));
add('ton.v5',path,ton.WalletContractV5R1.create({workchain:0,publicKey:pub}).address.toString({bounceable:false}));
path="m/44'/397'/0'";add('near',path,Buffer.from(ed25519.getPublicKey(slip(path))).toString('hex'));
path="m/44'/118'/0'/0/0";const hash=Buffer.from(ripemd160(sha256(secp256k1.getPublicKey(secp(path),true))));
add('cosmos',path,bech32.encode('cosmos',bech32.toWords(hash)));
add('osmosis',path,bech32.encode('osmo',bech32.toWords(hash)));
path="m/44'/1237'/0'/0/0";pub=secp256k1.getPublicKey(secp(path),true).subarray(1);add('nostr',path,bech32.encode('npub',bech32.toWords(pub)));
path="m/44'/9004'/0'/0/0";const starkKey=stark.grindKey(secp(path));add('starknet',path,stark.getStarkKey(starkKey));
const entropy=Buffer.alloc(16);const cRoot=cardano.Bip32PrivateKey.from_bip39_entropy(entropy,Buffer.alloc(0));
const account=cRoot.derive(0x80000000+1852).derive(0x80000000+1815).derive(0x80000000);
const pay=account.derive(0).derive(0).to_public().to_raw_key();const stake=account.derive(2).derive(0).to_public().to_raw_key();
const address=cardano.BaseAddress.new(1,cardano.Credential.from_keyhash(pay.hash()),cardano.Credential.from_keyhash(stake.hash())).to_address().to_bech32();
add('cardano',"m/1852'/1815'/0'/0/0",address);
const solSeed=slip("m/44'/501'/0'/0'");const solPair=Buffer.concat([solSeed,Buffer.from(ed25519.getPublicKey(solSeed))]);
const suiSeed=slip("m/44'/784'/0'/0'/0'");
const key=secp("m/84'/0'/0'/0/0");const wif=base58.encode(checksum(Buffer.concat([Buffer.from([0x80]),key,Buffer.from([1])])));
const legacyKey=secp("m/44'/0'/0'/0/0");const legacyUncompressed=base58.encode(checksum(Buffer.concat([Buffer.from([0x80]),legacyKey])));
const legacyUncompressedAddress=btc.payments.p2pkh({pubkey:Buffer.from(secp256k1.getPublicKey(legacyKey,false))}).address;
const eosKey=secp("m/44'/194'/0'/0/0");const eosPub=Buffer.from(secp256k1.getPublicKey(eosKey,true));
add('eos',"m/44'/194'/0'/0/0",'EOS'+base58.encode(Buffer.concat([eosPub,Buffer.from(ripemd160(eosPub)).subarray(0,4)])));
const eosWIF=base58.encode(checksum(Buffer.concat([Buffer.from([0x80]),eosKey])));
const eosPVT='PVT_K1_'+base58.encode(Buffer.concat([eosKey,Buffer.from(ripemd160(Buffer.concat([eosKey,Buffer.from('K1')]))).subarray(0,4)]));
const nearSeed=slip("m/44'/397'/0'");const nearKey='ed25519:'+base58.encode(Buffer.concat([nearSeed,Buffer.from(ed25519.getPublicKey(nearSeed))]));
const nostrKey=bech32.encode('nsec',bech32.toWords(secp("m/44'/1237'/0'/0/0")));
const cardanoKey=Buffer.concat([Buffer.from(account.derive(0).derive(0).to_raw_key().as_bytes()),Buffer.from(account.derive(2).derive(0).to_raw_key().as_bytes())]).toString('hex');
const tonSeed=slip("m/44'/607'/0'");const tonPair=Buffer.concat([tonSeed,Buffer.from(ed25519.getPublicKey(tonSeed))]).toString('hex');
const ltc={messagePrefix:'\x19Litecoin Signed Message:\n',bech32:'ltc',bip32:{public:0x0488b21e,private:0x0488ade4},pubKeyHash:0x30,scriptHash:0x32,wif:0xb0};
for(const [id,path,kind] of [ ['ltc.segwit',"m/84'/2'/0'/0/0",'p2wpkh'],['ltc.legacy',"m/44'/2'/0'/0/0",'p2pkh'],['ltc.nested',"m/49'/2'/0'/0/0",'nested'],['ltc.nested.compat',"m/49'/2'/0'/0/0",'compat'],['ltc.taproot',"m/86'/2'/0'/0/0",'p2tr'] ]) {
 const pubkey=Buffer.from(secp256k1.getPublicKey(secp(path),true));const network=kind==='compat'?{...ltc,scriptHash:5}:ltc;
 const payment=kind==='nested'||kind==='compat'?btc.payments.p2sh({redeem:btc.payments.p2wpkh({pubkey,network}),network}):kind==='p2tr'?btc.payments.p2tr({internalPubkey:pubkey.subarray(1),network}):btc.payments[kind]({pubkey,network});add(id,path,payment.address);
}
function mweb(scan,spend,index) {
 const indexBytes=Buffer.alloc(4);indexBytes.writeUInt32LE(index);
 const tweak=BigInt('0x'+Buffer.from(blake3(Buffer.concat([Buffer.from('A'),indexBytes,scan]))).toString('hex'));
 const n=secp256k1.CURVE.n;const spendI=(BigInt('0x'+spend.toString('hex'))+tweak)%n;
 const scanI=(BigInt('0x'+scan.toString('hex'))*spendI)%n;
 const pub=Buffer.concat([Buffer.from(secp256k1.ProjectivePoint.BASE.multiply(scanI).toRawBytes(true)),Buffer.from(secp256k1.ProjectivePoint.BASE.multiply(spendI).toRawBytes(true))]);
 return bech32.encode('ltcmweb',[0,...bech32.toWords(pub)],200);
}
const mwebScan=secp("m/0'/100'/0'");const mwebSpend=secp("m/0'/100'/1'");
add('ltc.mweb',"m/0'/100'",mweb(mwebScan,mwebSpend,0));
const ltcKey=secp("m/84'/2'/0'/0/0");const litecoinWIF=base58.encode(checksum(Buffer.concat([Buffer.from([0xb0]),ltcKey,Buffer.from([1])])));
const ltcLegacyKey=secp("m/44'/2'/0'/0/0");const litecoinUncompressedWIF=base58.encode(checksum(Buffer.concat([Buffer.from([0xb0]),ltcLegacyKey])));
const litecoinUncompressedAddress=btc.payments.p2pkh({pubkey:Buffer.from(secp256k1.getPublicKey(ltcLegacyKey,false)),network:ltc}).address;
const litecoinMwebPair=mwebScan.toString('hex')+':'+mwebSpend.toString('hex');
const witnessScript=btc.payments.p2ms({m:2,pubkeys:[1,2,3].map(i=>Buffer.from(secp256k1.getPublicKey(BigInt(i),true))),network:ltc});
const litecoinP2WSH=btc.payments.p2wsh({redeem:witnessScript,network:ltc}).address;
const litecoinMultisig=btc.payments.p2sh({redeem:witnessScript,network:ltc}).address;
const fixtures={phrase,accounts,privateKeys:{litecoinWIF,litecoinUncompressedWIF,litecoinUncompressedAddress,litecoinMwebPair,litecoinP2WSH,litecoinMultisig,eosWIF,eosPVT,nearKey,nostrKey,cardanoKey,tonPair,solanaBase58:base58.encode(solPair),solanaJSON:JSON.stringify(Array.from(solPair)),solanaSeed:Buffer.from(solSeed).toString('hex'),suiBech32:bech32.encode('suiprivkey',bech32.toWords(Buffer.concat([Buffer.from([0]),suiSeed]))),aptosAIP80:'ed25519-priv-0x'+Buffer.from(slip("m/44'/637'/0'/0'/0'")).toString('hex'),bitcoinWIF:wif,legacyUncompressedWIF:legacyUncompressed,legacyUncompressedAddress,starkKey:starkKey.padStart(64,'0')}};
const mwebWords=bech32.decode(accounts['ltc.mweb'].address,200).words;
fixtures.invalidLitecoinAddresses=[
 bech32m.encode('ltcmweb',mwebWords,200),
 bech32.encode('ltcmweb',[1,...mwebWords.slice(1)],200),
 bech32.encode('ltcmweb',[0,...bech32.toWords(Buffer.alloc(66,0xff))],200),
 bech32.encode('tmweb',mwebWords,200),
 'ltcmweb1'+accounts['ltc.mweb'].address.slice(8).toUpperCase(),
 bech32.encode('ltc',[0,...bech32.toWords(Buffer.alloc(21,1))]),
 bech32m.encode('ltc',[0,...bech32.toWords(Buffer.alloc(20,1))]),
 bech32.encode('ltc',[1,...bech32.toWords(Buffer.alloc(32,1))])
];
fs.mkdirSync('Tests/WalletCoreTests/Fixtures',{recursive:true});fs.writeFileSync('Tests/WalletCoreTests/Fixtures/multichain-reference.json',JSON.stringify(fixtures,null,2)+'\n');
console.log('Generated '+Object.keys(accounts).length+' independent public address fixtures.');
