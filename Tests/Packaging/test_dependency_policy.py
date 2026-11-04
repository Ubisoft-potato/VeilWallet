"""Advisory dispositions require a reviewed, physically reduced proof runtime."""
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('dependencies', ROOT/'Scripts/check-dependencies.py')
deps = importlib.util.module_from_spec(spec); spec.loader.exec_module(deps)


class DependencyPolicyTests(unittest.TestCase):
    def test_only_the_specific_removed_verifier_advisory_can_be_reviewed(self):
        query = dict(package=dict(name='snarkjs', ecosystem='npm'), version='0.1.20')
        self.assertTrue(deps.reviewed_advisory(query, 'GHSA-xp5g-jhg3-3rg2', True))
        self.assertFalse(deps.reviewed_advisory(query, 'GHSA-xp5g-jhg3-3rg2', False))
        self.assertFalse(deps.reviewed_advisory(query, 'GHSA-new-unreviewed', True))
        query['version'] = 'different-version'
        self.assertFalse(deps.reviewed_advisory(query, 'GHSA-xp5g-jhg3-3rg2', True))

    def test_a_changed_native_verification_boundary_invalidates_source_review(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            required = ['Tools/PrivacyProof/main.cjs', 'Tools/PrivacyProof/snarkjs-prover-entry.cjs', 'Sources/WalletCore/Networking/PrivacyPoolClient.swift']
            for name in required:
                p = root/name; p.parent.mkdir(parents=True, exist_ok=True); p.write_bytes(b'public reviewed source')
            p = root/'Configuration/PrivacyDependencyPolicy.json'; p.parent.mkdir()
            p.write_text(json.dumps({'snarkjs': {'sourceGuards': {name: hashlib.sha256((root/name).read_bytes()).hexdigest() for name in required}}}))
            deps.source_policy(root)
            (root/required[-1]).write_bytes(b'changed native verifier')
            with self.assertRaises(ValueError): deps.source_policy(root)

    def test_reintroduced_verifier_file_blocks_the_runtime(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); entry = root/'entry.cjs'; entry.write_bytes(b'public restricted entry')
            runtime = root/'Vendor/PrivacyRuntime'; package = runtime/'node_modules/snarkjs'; package.mkdir(parents=True)
            (package/'package.json').write_text(json.dumps({'version': '0.1.20'})); (package/'index.js').write_bytes(entry.read_bytes())
            (runtime/'LOAD_GRAPH.json').write_text('[]')
            policy = dict(version='0.1.20', entry='entry.cjs', excludedSourcePrefixes=['src/verifier', 'src/setup', 'src/prover'])
            self.assertTrue(deps.runtime_policy(policy, root))
            (package/'src').mkdir(); (package/'src/verifier_groth.js').write_bytes(b'excluded fixture')
            with self.assertRaises(ValueError): deps.runtime_policy(policy, root)


if __name__ == '__main__': unittest.main()
