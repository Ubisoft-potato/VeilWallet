// SPDX-License-Identifier: GPL-3.0-or-later
// Offline adapter only. Cryptography and witness/proof generation are the exact
// pinned upstream Tornado CLI dependencies. No RPC, wallet signing or relaying.
'use strict';
const fs = require('node:fs');
const path = require('node:path');
Object.defineProperty(globalThis, 'navigator', {value: {hardwareConcurrency: 2}, configurable: true});
const snarkjs = require('snarkjs');
const babyJub = require('circomlib/src/babyjub');
const pedersen = require('circomlib/src/pedersenHash');
const MerkleTree = require('fixed-merkle-tree');
const FIELD = 21888242871839275222246405745257275088548364400416034343698204186575808495617n;
const word = value => '0x' + snarkjs.bigInt(value).toString(16).padStart(64, '0');
function integer(value) {
  if (typeof value !== 'string' || !/^(0x[0-9a-fA-F]+|[0-9]+)$/.test(value) || value.length > 100) throw Error('invalid_integer');
  const n = BigInt(value); if (n < 0n || n >= FIELD) throw Error('field_range'); return n;
}
function deposit(preimage) {
  if (typeof preimage !== 'string' || !/^[0-9a-fA-F]{124}$/.test(preimage)) throw Error('invalid_preimage');
  const raw = Buffer.from(preimage, 'hex');
  const nullifier = snarkjs.bigInt.leBuff2int(raw.subarray(0, 31));
  const secret = snarkjs.bigInt.leBuff2int(raw.subarray(31));
  const commitment = babyJub.unpackPoint(pedersen.hash(raw))[0];
  const nullifierHash = babyJub.unpackPoint(pedersen.hash(raw.subarray(0, 31)))[0];
  return {nullifier, secret, commitment, nullifierHash};
}
async function run(request, artifacts) {
  if (!request || typeof request !== 'object') throw Error('invalid_request');
  const d = deposit(request.preimage);
  if (request.action === 'derive') return {commitment: word(d.commitment), nullifierHash: word(d.nullifierHash)};
  if (!['proof', 'publicFixtureProof'].includes(request.action)) throw Error('unsupported_action');
  if (request.action === 'publicFixtureProof' && request.preimage !== '00'.repeat(62)) throw Error('fixture_only');
  const recipient = integer(request.recipient), relayer = integer(request.relayer), fee = integer(request.fee);
  if (recipient === 0n || recipient >= 1n << 160n || relayer >= 1n << 160n) throw Error('invalid_recipient');
  let leaves = request.action === 'publicFixtureProof' ? [d.commitment.toString()] : request.leaves;
  if (!Array.isArray(leaves) || leaves.length === 0 || leaves.length > 2 ** 20) throw Error('invalid_tree');
  leaves = leaves.map(x => integer(x).toString());
  const commitment = d.commitment.toString();
  const index = leaves.indexOf(commitment);
  if (index < 0 || leaves.lastIndexOf(commitment) !== index) throw Error('missing_or_duplicate_deposit');
  const tree = new MerkleTree(20, leaves);
  const merkle = tree.path(index);
  const input = {
    root: tree.root(), nullifierHash: d.nullifierHash,
    recipient: snarkjs.bigInt(recipient.toString()), relayer: snarkjs.bigInt(relayer.toString()),
    fee: snarkjs.bigInt(fee.toString()), refund: snarkjs.bigInt(0),
    nullifier: d.nullifier, secret: d.secret, pathElements: merkle.pathElements, pathIndices: merkle.pathIndices
  };
  const circuit = JSON.parse(fs.readFileSync(path.join(artifacts, 'tornado.json'), 'utf8'));
  const key = fs.readFileSync(path.join(artifacts, 'tornadoProvingKey.bin'));
  const buildGroth16 = require('websnark/src/groth16');
  const utils = require('websnark/src/utils');
  const engine = await buildGroth16();
  try {
    const result = await utils.genWitnessAndProve(engine, input, circuit, key.buffer.slice(key.byteOffset, key.byteOffset + key.byteLength));
    const expected = [input.root, input.nullifierHash, input.recipient, input.relayer, input.fee, input.refund].map(x => snarkjs.bigInt(x).toString());
    if (!Array.isArray(result.publicSignals) || result.publicSignals.length !== 6 || result.publicSignals.some((x, i) => snarkjs.bigInt(x).toString() !== expected[i])) throw Error('public_signal_mismatch');
    const {proof} = utils.toSolidityInput(result);
    if (!/^0x[0-9a-fA-F]{512}$/.test(proof)) throw Error('proof_size');
    return {commitment: word(d.commitment), nullifierHash: word(d.nullifierHash), root: word(input.root), proof, publicSignals: expected};
  } finally {
    for (const worker of engine.workers) await worker.terminate();
  }
}
module.exports = {run};
if (require.main === module) {
  // Fixed protocol on stdin/stdout. Never forward dependency errors or input.
  console.log = console.error = console.warn = console.time = console.timeEnd = () => {};
  let size = 0, buffers = [];
  process.stdin.on('data', b => { size += b.length; if (size > 100 * 1024 * 1024) process.exit(2); buffers.push(b); });
  process.stdin.on('end', async () => {
    try {
      const value = await run(JSON.parse(Buffer.concat(buffers).toString('utf8')), path.join(__dirname, 'artifacts'));
      process.stdout.write(JSON.stringify({result: value}), () => process.exit(0));
    } catch (_) { process.stdout.write('{"error":"offline_proof_failed"}', () => process.exit(1)); }
  });
}
