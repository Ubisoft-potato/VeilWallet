// SPDX-License-Identifier: GPL-3.0-or-later
// Developer-only, hash-bound API reduction. No cryptographic primitive changes.
'use strict';
const fs = require('node:fs'), path = require('node:path'), crypto = require('node:crypto');
const root = path.resolve(__dirname, '..');
const policy = JSON.parse(fs.readFileSync(path.join(root, 'Configuration/PrivacyDependencyPolicy.json'))).snarkjs;
const moduleRoot = path.join(root, 'Tools/PrivacyProof/node_modules');
const entry = fs.readFileSync(path.join(root, policy.entry));
const digest = bytes => crypto.createHash('sha256').update(bytes).digest('hex');
const patched = digest(entry), changes = [];
function visit(directory) {
  for (const item of fs.readdirSync(directory, {withFileTypes: true})) {
    if (!item.isDirectory() || item.isSymbolicLink()) continue;
    const location = path.join(directory, item.name);
    if (item.name === 'snarkjs' && fs.existsSync(path.join(location, 'package.json'))) {
      const pkg = JSON.parse(fs.readFileSync(path.join(location, 'package.json')));
      if (pkg.version !== policy.version) throw Error('Unexpected snarkjs version');
      const target = path.join(location, 'index.js'), original = digest(fs.readFileSync(target));
      if (![policy.originalEntrySHA256, patched].includes(original)) throw Error('Unexpected snarkjs entry hash');
      fs.writeFileSync(target, entry);
      const exported = Object.keys(require(target)).sort();
      if (JSON.stringify(exported) !== JSON.stringify([...policy.exports].sort())) throw Error('Unexpected prover exports');
      changes.push({package: path.relative(moduleRoot, location), originalEntrySHA256: policy.originalEntrySHA256, runtimeEntrySHA256: patched});
    }
    visit(location);
  }
}
visit(moduleRoot);
if (changes.length === 0) throw Error('No pinned snarkjs package found');
fs.mkdirSync(path.join(root, '.build'), {recursive: true});
fs.writeFileSync(path.join(root, '.build/privacy-dependency-patches.json'), JSON.stringify({policy: 'Configuration/PrivacyDependencyPolicy.json', changes}, null, 2) + '\n');
process.stdout.write('Prepared hash-verified prover-only snarkjs entry points: ' + changes.length + '\n');
