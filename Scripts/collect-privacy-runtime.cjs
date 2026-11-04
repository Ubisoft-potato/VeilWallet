// SPDX-License-Identifier: GPL-3.0-or-later
// Developer packaging step: collect only packages actually loaded by a complete
// public-fixture proof. Preserve their source and licenses; exclude native addons.
'use strict';
const fs = require('node:fs'), path = require('node:path'), Module = require('node:module');
const root = path.resolve(__dirname, '..');
const moduleRoot = path.join(root, 'Tools/PrivacyProof/node_modules');
const loaded = new Set();
const original = Module._load;
Module._load = function(name, parent, isMain) {
  const resolved = Module._resolveFilename(name, parent, isMain);
  if (typeof resolved === 'string' && resolved.startsWith(moduleRoot + path.sep)) loaded.add(resolved);
  return original.apply(this, arguments);
};
async function main() {
  const helper = require('../Tools/PrivacyProof/main.cjs');
  const result = await helper.run({action:'publicFixtureProof',preimage:'00'.repeat(62),recipient:'0x000000000000000000000000000000000000dEaD',relayer:'0',fee:'0'}, path.join(root,'Vendor/PrivacyRuntime/artifacts'));
  const packages = new Set();
  for (const file of loaded) {
    let directory = path.dirname(file);
    while (directory.startsWith(moduleRoot)) {
      if (fs.existsSync(path.join(directory, 'package.json'))) { packages.add(directory); break; }
      directory = path.dirname(directory);
    }
  }
  const destination = path.join(root,'Vendor/PrivacyRuntime/node_modules');
  fs.rmSync(destination,{recursive:true,force:true});
  fs.mkdirSync(destination,{recursive:true});
  const notices=[];
  for(const source of [...packages].sort()) {
    const relative=path.relative(moduleRoot,source), target=path.join(destination,relative);
    fs.cpSync(source,target,{recursive:true,filter:p=>{
      const rel=path.relative(source,p).split(path.sep);
      if (path.basename(source)==='websnark' && ['test','benchmarks','example'].includes(rel[0])) return false;
      if (path.basename(source)==='websnark' && rel[0]==='build' && rel.length>1 && rel[1]!=='groth16_wasm.js') return false;
      return !rel.includes('node_modules') && !rel.includes('.git') && !p.endsWith('.node') && !rel.includes('prebuilds');
    }});
    const pkg=JSON.parse(fs.readFileSync(path.join(source,'package.json'),'utf8'));
    notices.push({name:pkg.name,version:pkg.version,license:pkg.license??pkg.licenses??null,repository:pkg.repository??null});
  }
  fs.copyFileSync(path.join(root,'Tools/PrivacyProof/main.cjs'),path.join(root,'Vendor/PrivacyRuntime/main.cjs'));
  fs.copyFileSync(path.join(root,'Tools/PrivacyProof/package-lock.json'),path.join(root,'Vendor/PrivacyRuntime/package-lock.json'));
  fs.writeFileSync(path.join(root,'Vendor/PrivacyRuntime/DEPENDENCIES.json'),JSON.stringify(notices,null,2)+'\n');
  fs.writeFileSync(path.join(root,'.build/privacy-public-proof.json'),JSON.stringify(result)+'\n');
  process.stdout.write('PASS: complete public-fixture Groth16 proof; collected '+notices.length+' source packages with native addons excluded\n');
}
main().then(()=>process.exit(0)).catch(e=>{process.stderr.write('Privacy runtime packaging failed: '+e.message+'\n');process.exit(1)});
