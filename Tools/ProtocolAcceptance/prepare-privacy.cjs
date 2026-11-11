// LOCAL FIXTURE ONLY. No public signing/broadcasting; private keys remain in RAM.
// Reinitializes catalog pool addresses on disposable Anvil forks with a real
// upstream ETHTornado, MiMC hasher and the fork's real on-chain verifier.
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const zlib = require('node:zlib');
const root = path.resolve(__dirname, '../..');
const directory = path.join(root, '.build/ProtocolAcceptance');
const { JsonRpcProvider, Wallet, NonceManager, Contract, ContractFactory, parseEther } = require(path.join(directory, 'node_modules/ethers'));
const generator = require(path.join(root, 'Vendor/PrivacyRuntime/node_modules/circomlib/src/mimcsponge_gencontract.js'));
const artifactPath = path.join(directory, 'contracts/ETHTornado.json');
const bytes = fs.readFileSync(artifactPath);
if (crypto.createHash('sha256').update(bytes).digest('hex') !== '5370c25ecfb57c366ea306c08961217f28c9ae1d2744e33c060d52e393ac4f35') throw Error('Unpinned ETHTornado artifact');
const artifact = JSON.parse(bytes);
const portsFile = process.env.VEIL_PROTOCOL_PORTS;
if (!portsFile) throw Error('VEIL_PROTOCOL_PORTS is required');
const ports = JSON.parse(fs.readFileSync(portsFile));
const pools = [
  [1, '0.1', '0x12D66f87A04A9E220743712cE6d9bB1B5616B8Fc'],
  [1, '1', '0x47CE0C6eD5B0Ce3d3A51fdb1C52DC66a7c3c2936'],
  [1, '10', '0x910Cbd523D972eb0a6f4cAe4618aD62622b39DbF'],
  [1, '100', '0xA160cdAB225685dA1d56aa342Ad8841c3b53f291'],
  [56, '0.1', '0x84443CFd09A48AF6eF360C6976C5392aC5023a1F'],
  [56, '1', '0xd47438C816c9E7f2E2888E060936a499Af9582b3'],
  [56, '10', '0x330bdFADE01eE9bF63C209Ee33102DD334618e0a'],
  [56, '100', '0x1E34A77868E19A6647b1f2F47B51ed72dEDE95DD']
];
let stage = 'initialization';
async function main() {
  const anchors = {};
  for (const id of [1, 56].filter(id => !process.env.VEIL_PRIVACY_CHAINS || process.env.VEIL_PRIVACY_CHAINS.split(',').includes(String(id)))) {
    if (!Number.isInteger(ports[id]) || ports[id] < 1 || ports[id] > 65535) throw Error('Invalid local port');
    const provider = new JsonRpcProvider('http://127.0.0.1:' + ports[id]);
    if ((await provider.getNetwork()).chainId !== BigInt(id)) throw Error('Wrong fixture chain');
    // anvil_nodeInfo distinguishes these disposable nodes from public RPCs.
    await provider.send('anvil_nodeInfo', []);
    const ephemeral = Wallet.createRandom().connect(provider);
    await provider.send('anvil_setBalance', [ephemeral.address, '0x' + parseEther('1000').toString(16)]);
    const signer = new NonceManager(ephemeral);
    stage = 'hasher deployment on chain ' + id;
    const hasher = await new ContractFactory(generator.abi, generator.createCode('mimcsponge', 220), signer).deploy({gasLimit: 12000000});
    await hasher.waitForDeployment();
    const linked = artifact.bytecode.replaceAll('__Hasher________________________________', (await hasher.getAddress()).slice(2));
    for (const [, amount, target] of pools.filter(row => row[0] === id)) {
      stage = 'pool deployment on chain ' + id + ' denomination ' + amount;
      const fixture = process.env.VEIL_PRIVACY_VERIFIER_CODE_FILE ? JSON.parse(fs.readFileSync(process.env.VEIL_PRIVACY_VERIFIER_CODE_FILE)) : null;
      const verifier = fixture ? fixture.address : await new Contract(target, ['function verifier() view returns(address)'], provider).verifier();
      if (fixture) {
        if (fixture.chainID !== undefined && fixture.chainID !== id) throw Error('Wrong verifier fixture chain');
        if (crypto.createHash('sha256').update(Buffer.from(fixture.code.slice(2), 'hex')).digest('hex') !== fixture.sha256) throw Error('Verifier fixture checksum mismatch');
        await provider.send('anvil_setCode', [verifier, fixture.code]);
      }
      if ((await provider.getCode(verifier)) === '0x') throw Error('Verifier missing');
      const fresh = await new ContractFactory(artifact.abi, linked, signer).deploy(verifier, parseEther(amount), 20, ephemeral.address, {gasLimit: 16000000});
      await fresh.waitForDeployment();
      const dump = JSON.parse(zlib.gunzipSync(Buffer.from((await provider.send('anvil_dumpState', [])).slice(2), 'hex')));
      const address = (await fresh.getAddress()).toLowerCase();
      const account = dump.accounts[address];
      if (!account?.code || !account.storage) throw Error('Fresh pool state missing');
      // Load only the freshly initialized pool account. This is an explicit
      // fixture replacement, never an assertion about mainnet pool history.
      dump.accounts[target.toLowerCase()] = account;
      const state = '0x' + zlib.gzipSync(Buffer.from(JSON.stringify(dump))).toString('hex');
      stage = 'pool state installation on chain ' + id;
      await provider.send('anvil_loadState', [state]);
      const installed = new Contract(target, artifact.abi, provider);
      if (await installed.denomination() !== parseEther(amount) || await installed.nextIndex() !== 0n) throw Error('Pool reset failed');
      console.log('Real privacy fixture installed: chain ' + id + ', denomination ' + amount);
    }
    anchors[id] = await provider.send('eth_blockNumber', []);
    provider.destroy();
  }
  const file = path.join(path.dirname(portsFile), 'privacy-anchors.json');
  const existing = fs.existsSync(file) ? JSON.parse(fs.readFileSync(file)) : {};
  fs.writeFileSync(file, JSON.stringify({...existing, ...anchors}), {mode:0o600});
}
main().catch(error => {
  const message = String(error.error?.message || error.shortMessage || 'validation').replace(/0x[0-9a-f]+/gi, '[hex redacted]').slice(0, 300);
  console.error('Privacy fixture setup failed: ' + stage + ' (' + (error.code || 'validation') + '): ' + message);
  process.exitCode = 1;
});
