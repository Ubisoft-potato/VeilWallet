"""Binary publication defaults closed and requires exact source/material evidence."""
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('release_policy', ROOT/'Scripts/check-release-policy.py')
policy = importlib.util.module_from_spec(spec); spec.loader.exec_module(policy)


class ReleasePolicyTests(unittest.TestCase):
    def test_default_policy_does_not_publish_binaries(self):
        self.assertFalse(policy.validate({'version': 1, 'enabled': False, 'materialsManifest': None}))
        workflow = (ROOT/'.github/workflows/macos-dmg.yml').read_text()
        self.assertIn("if: steps.distribution.outputs.enabled == 'true'", workflow)
        self.assertIn('check-release-policy.py --github-output', workflow)

    def test_enabled_without_source_materials_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(ValueError):
                policy.validate({'version': 1, 'enabled': True}, Path(directory), 'public-tree')

    def test_exact_tree_hash_and_relink_review_are_required(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); (root/'source.tar').write_bytes(b'public source fixture')
            manifest = dict(version=1, sourceTree='public-tree', reviewedForBinaryDistribution=True, relinkVerified=True,
                components=sorted(policy.COMPONENTS), artifacts=[dict(path='source.tar', sha256=hashlib.sha256((root/'source.tar').read_bytes()).hexdigest())])
            (root/'materials.json').write_text(json.dumps(manifest))
            (root/'build').mkdir(); (root/'build/BUILD-INFO.json').write_text(json.dumps(dict(sourceTree='public-tree', dirty=False)))
            enabled = dict(version=1, enabled=True, materialsManifest='materials.json')
            self.assertTrue(policy.validate(enabled, root, 'public-tree'))
            with self.assertRaises(ValueError): policy.validate(enabled, root, 'different-tree')
            (root/'build/BUILD-INFO.json').write_text(json.dumps(dict(sourceTree='public-tree', dirty=True)))
            with self.assertRaises(ValueError): policy.validate(enabled, root, 'public-tree')
            (root/'build/BUILD-INFO.json').write_text(json.dumps(dict(sourceTree='public-tree', dirty=False)))
            (root/'source.tar').write_bytes(b'changed source')
            with self.assertRaises(ValueError): policy.validate(enabled, root, 'public-tree')

    def test_material_paths_cannot_escape(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(ValueError): policy.local_file(Path(directory), '../outside')

    def test_only_verified_source_deliveries_are_staged_for_upload(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); (root/'source.tar').write_bytes(b'public source fixture'); (root/'unrelated.txt').write_bytes(b'excluded public canary')
            manifest = dict(version=1, sourceTree='public-tree', reviewedForBinaryDistribution=True, relinkVerified=True,
                components=sorted(policy.COMPONENTS), artifacts=[dict(path='source.tar', sha256=hashlib.sha256((root/'source.tar').read_bytes()).hexdigest())])
            (root/'materials.json').write_text(json.dumps(manifest))
            (root/'build').mkdir(); (root/'build/BUILD-INFO.json').write_text(json.dumps(dict(sourceTree='public-tree', dirty=False)))
            policy.stage_materials(dict(version=1, enabled=True, materialsManifest='materials.json'), root, 'public-tree')
            self.assertEqual({p.name for p in (root/'build/release-materials').iterdir()}, {'source.tar', 'MANIFEST.json'})


if __name__ == '__main__': unittest.main()
