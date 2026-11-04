"""The thin native archive and Swift build/test must use the same architecture."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class SwiftWrapperTests(unittest.TestCase):
    def invoke(self, command, architecture, plugin=False):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); scripts = root/'Scripts'; scripts.mkdir()
            shutil.copyfile(ROOT/'Scripts/swift.sh', scripts/'swift.sh'); (scripts/'swift.sh').chmod(0o755)
            (scripts/'build-chain-core.sh').write_text('#!/bin/sh\nexit 0\n'); (scripts/'build-chain-core.sh').chmod(0o755)
            tools = root/'tools'; tools.mkdir()
            fixtures = {
                'uname': '#!/bin/sh\nprintf "%s\\n" "$VEIL_TEST_MACHINE"\n',
                'xcode-select': '#!/bin/sh\nprintf "%s\\n" "$VEIL_TEST_DEVELOPER"\n',
                'swift': '#!/usr/bin/env python3\nimport json,os,sys\nfrom pathlib import Path\n'
                         'if sys.argv[1:] == ["build","--help"]: print("swiftbuild")\n'
                         'else: Path(os.environ["VEIL_TEST_ARGV"]).write_text(json.dumps(sys.argv[1:]))\n',
            }
            for name, source in fixtures.items():
                (tools/name).write_text(source); (tools/name).chmod(0o755)
            developer = root/'Developer'
            if plugin:
                file = developer/'usr/lib/swift/host/plugins/testing/libTestingMacros.dylib'
                file.parent.mkdir(parents=True); file.write_bytes(b'public plugin fixture')
            output = root/'argv.json'
            env = dict(os.environ, PATH=str(tools)+os.pathsep+os.environ['PATH'], VEIL_TEST_MACHINE=architecture,
                       VEIL_TEST_DEVELOPER=str(developer), VEIL_TEST_ARGV=str(output))
            subprocess.run([str(scripts/'swift.sh'), *command], cwd=root, env=env, check=True, capture_output=True)
            return json.loads(output.read_text())

    def test_release_pins_only_the_host_architecture(self):
        args = self.invoke(['build', '-c', 'release'], 'arm64')
        self.assertEqual(args[:3], ['build', '-c', 'release'])
        self.assertEqual(args.count('--arch'), 1)
        self.assertEqual(args[args.index('--arch')+1], 'arm64')
        self.assertNotIn('x86_64', args)
        self.assertEqual(args[args.index('--build-system')+1], 'swiftbuild')

    def test_test_and_bin_path_queries_keep_the_architecture(self):
        for command in [['test'], ['build', '-c', 'release', '--show-bin-path']]:
            with self.subTest(command=command):
                args = self.invoke(command, 'x86_64')
                self.assertEqual(args[args.index('--arch')+1], 'x86_64')
                self.assertEqual(args.count('--arch'), 1)

    def test_testing_plugin_branch_also_pins_architecture(self):
        args = self.invoke(['test'], 'arm64', plugin=True)
        self.assertEqual(args[args.index('--arch')+1], 'arm64')
        self.assertIn('-load-plugin-library', args)


if __name__ == '__main__': unittest.main()
