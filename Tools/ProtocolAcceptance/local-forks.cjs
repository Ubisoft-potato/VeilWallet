// Developer-only chain execution. Upstream RPC is read-only and Tor-routed.
// Signed transactions are accepted only by the isolated loopback Anvil nodes.
const fs = require('node:fs');
const path = require('node:path');
const http = require('node:http');
const https = require('node:https');
const net = require('node:net');
const { spawn } = require('node:child_process');

const root = path.resolve(__dirname, '../..');
const tools = path.join(root, '.build/ProtocolAcceptance');
const { SocksProxyAgent } = require(path.join(tools, 'node_modules/socks-proxy-agent'));
const directory = fs.mkdtempSync(path.join(tools, 'fork-run-'));
const children = [];
const methods = new Set([
  'eth_chainId', 'eth_blockNumber', 'eth_getBlockByNumber', 'eth_getBlockByHash',
  'eth_getBalance', 'eth_getCode', 'eth_getStorageAt', 'eth_getTransactionCount',
  'eth_getTransactionByHash', 'eth_getTransactionReceipt', 'eth_getLogs',
  'eth_gasPrice', 'eth_maxPriorityFeePerGas', 'eth_feeHistory', 'eth_call',
  'eth_estimateGas', 'eth_getProof', 'net_version'
]);
const endpoints = new Map([[1, 'https://eth.drpc.org'], [56, 'https://bsc-rpc.publicnode.com']]);

function stop() {
  for (const child of children) child.kill('SIGTERM');
}
process.on('SIGINT', () => { stop(); process.exit(130); });
process.on('SIGTERM', () => { stop(); process.exit(143); });
process.on('exit', stop);

async function freePort() {
  const listener = net.createServer();
  await new Promise(resolve => listener.listen(0, '127.0.0.1', resolve));
  const port = listener.address().port;
  await new Promise(resolve => listener.close(resolve));
  return port;
}

function forwarded(url, agent, body) {
  return new Promise((resolve, reject) => {
    const request = https.request(url, {
      method: 'POST', agent,
      headers: { 'content-type': 'application/json', 'content-length': body.length }
    }, response => {
      const chunks = [];
      let count = 0;
      response.on('data', chunk => {
        count += chunk.length;
        if (count > 16 * 1024 * 1024) request.destroy(new Error('RPC response too large'));
        else chunks.push(chunk);
      });
      response.on('end', () => {
        if (response.statusCode !== 200) reject(new Error('RPC HTTP status ' + response.statusCode));
        else resolve(Buffer.concat(chunks));
      });
      response.on('error', reject);
    });
    request.setTimeout(90000, () => request.destroy(new Error('Tor RPC timeout')));
    request.on('error', reject);
    request.end(body);
  });
}

async function main() {
  const socks = await freePort();
  const dataDirectory = path.join(directory, 'tor');
  fs.mkdirSync(dataDirectory, { mode: 0o700 });
  const tor = spawn(path.join(root, 'Vendor/Tor/tor/tor'), [
    '--ClientOnly', '1', '--SocksPort', '127.0.0.1:' + socks + ' IsolateSOCKSAuth',
    '--DataDirectory', dataDirectory, '--SafeSocks', '1', '--SafeLogging', '1',
    '--AvoidDiskWrites', '1', '--__OwningControllerProcess', String(process.pid)
  ], { stdio: ['ignore', 'pipe', 'ignore'], cwd: directory });
  children.push(tor);
  await new Promise((resolve, reject) => {
    const timeout = setTimeout(() => reject(new Error('Tor bootstrap timed out')), 180000);
    tor.stdout.on('data', chunk => {
      if (chunk.toString().includes('Bootstrapped 100%')) { clearTimeout(timeout); resolve(); }
    });
    tor.once('exit', () => { clearTimeout(timeout); reject(new Error('Test Tor exited')); });
  });
  const agents = new Map([...endpoints.keys()].map(id => [id, new SocksProxyAgent('socks5h://fork-' + id + ':test@127.0.0.1:' + socks, { keepAlive: true })]));
  const gateway = http.createServer(async (request, response) => {
    try {
      const id = Number(request.url.slice(1));
      if (request.method !== 'POST' || !endpoints.has(id)) throw new Error('Invalid fork upstream');
      const chunks = [];
      let length = 0;
      for await (const chunk of request) {
        length += chunk.length;
        if (length > 1024 * 1024) throw new Error('Fork request too large');
        chunks.push(chunk);
      }
      const body = Buffer.concat(chunks);
      const parsed = JSON.parse(body);
      const batch = Array.isArray(parsed) ? parsed : [parsed];
      if (batch.length === 0 || batch.length > 100 || batch.some(item => !methods.has(item.method))) throw new Error('Public RPC writes are prohibited');
      const result = await forwarded(endpoints.get(id), agents.get(id), body);
      response.writeHead(200, { 'content-type': 'application/json' });
      response.end(result);
    } catch (error) {
      response.writeHead(502, { 'content-type': 'application/json' });
      response.end(JSON.stringify({ error: { code: -32000, message: error.message } }));
    }
  });
  await new Promise(resolve => gateway.listen(0, '127.0.0.1', resolve));
  const gatewayPort = gateway.address().port;
  const ports = {};
  for (const id of endpoints.keys()) {
    const port = await freePort();
    const node = spawn(process.env.VEIL_ANVIL || 'anvil', [
      '--host', '127.0.0.1', '--port', String(port), '--chain-id', String(id),
      '--accounts', '0', '--silent', '--fork-url', 'http://127.0.0.1:' + gatewayPort + '/' + id
    ], { stdio: ['ignore', 'ignore', 'pipe'], cwd: directory });
    children.push(node);
    // Drain diagnostics without printing RPC parameters or wallet identifiers.
    node.stderr.resume();
    let ready = false;
    for (let attempt = 0; attempt < 90; attempt++) {
      if (node.exitCode !== null) throw new Error('Fork node exited for chain ' + id);
      try {
        const response = await fetch('http://127.0.0.1:' + port, {
          method: 'POST', headers: { 'content-type': 'application/json' },
          body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'eth_chainId', params: [] }),
          signal: AbortSignal.timeout(2000)
        });
        const result = await response.json();
        if (result.result === '0x' + id.toString(16)) { ready = true; break; }
      } catch {}
      await new Promise(resolve => setTimeout(resolve, 1000));
    }
    if (!ready) throw new Error('Fork node did not initialize for chain ' + id);
    ports[id] = port;
    console.log('Isolated execution fork ready for chain ' + id);
  }
  const configuration = path.join(directory, 'ports.json');
  fs.writeFileSync(configuration, JSON.stringify(ports), { mode: 0o600 });
  console.log('VEIL_PROTOCOL_PORTS=' + configuration);
  process.stdin.resume();
}

main().catch(error => {
  console.error(error.message);
  stop();
  process.exitCode = 1;
});
