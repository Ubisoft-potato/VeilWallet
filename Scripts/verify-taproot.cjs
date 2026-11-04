// Developer-only independent verification. Signed fixtures arrive over stdin,
// never command arguments, disk output or console logs. No user vault is used.
const path = require('node:path');
const { createRequire } = require('node:module');
const req = createRequire(path.resolve(__dirname, '../.build/verification/package.json'));
const btc = req('bitcoinjs-lib'), secp = req('tiny-secp256k1');
let input = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', chunk => { input += chunk; if (input.length > 2_000_000) process.exit(2); });
process.stdin.on('end', () => {
  try {
    const { signed, inputs } = JSON.parse(input), tx = btc.Transaction.fromHex(signed);
    if (tx.ins.length !== inputs.length || !inputs.length) throw Error();
    const outputs = inputs.map(row => {
      const previous = btc.Transaction.fromHex(row.previous);
      if (previous.getId() !== row.txid) throw Error();
      return previous.outs[row.index];
    });
    tx.ins.forEach((entry, i) => {
      const script = outputs[i].script;
      if (script.length !== 34 || script[0] !== 0x51 || script[1] !== 0x20 || entry.witness.length !== 1 || entry.witness[0].length !== 64) throw Error();
      const digest = tx.hashForWitnessV1(i, outputs.map(x => x.script), outputs.map(x => x.value), btc.Transaction.SIGHASH_DEFAULT);
      if (!secp.verifySchnorr(digest, script.subarray(2), entry.witness[0])) throw Error();
    });
    process.exit(0);
  } catch { process.stderr.write('Independent Taproot verification failed\n'); process.exit(1); }
});
