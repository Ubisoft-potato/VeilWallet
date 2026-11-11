// Developer-only fresh TESTNET credentials. Never import a user's wallet here.
const fs = require('node:fs'), path = require('node:path');
const {execFileSync} = require('node:child_process');
const root = path.resolve(__dirname, '../..');
const directory = path.join(root, '.build/ProtocolAcceptance');
const {Wallet} = require(path.join(directory, 'node_modules/ethers'));
const {TronWeb} = require(path.join(directory, 'node_modules/tronweb'));
const file = path.join(directory, 'test-wallets.json');
const funding = path.join(directory, 'funding.json');
execFileSync('git', ['check-ignore', '--quiet', '--', file], {cwd:root});
if (fs.existsSync(file) || fs.existsSync(funding)) throw Error('Test credentials or funding metadata already exist; refusing to replace them');
const evm = Wallet.createRandom(), tron = Wallet.createRandom();
fs.writeFileSync(file, JSON.stringify({evm:evm.privateKey,tron:tron.privateKey.slice(2)}), {flag:'wx',mode:0o600});
fs.writeFileSync(funding, JSON.stringify({evm:evm.address,tron:TronWeb.address.fromPrivateKey(tron.privateKey.slice(2))}), {flag:'wx',mode:0o600});
console.log('Created separate disposable test credentials and funding metadata in ignored .build/ProtocolAcceptance.');
