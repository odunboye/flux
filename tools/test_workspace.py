import copy
from pathlib import Path
import tempfile
import unittest
import subprocess
import sys
from unittest.mock import patch

import workspace


class WorkspaceTests(unittest.TestCase):
    def test_child_cleanup(self):
        process = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(30)'], start_new_session=True)
        try:
            workspace.stop_group(process)
            self.assertIsNotNone(process.poll())
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()

    def test_current_workspace(self):
        workspace.check(workspace.load())

    def test_dependency_parser(self):
        self.assertEqual(workspace.dependencies('package x\ndepends = iris -- comment\n  , json-simple\nmodules = X\n'), {'iris', 'json-simple'})

    def test_config_deterministic(self):
        manifest = workspace.load()
        other = copy.deepcopy(manifest)
        other['packages'] = dict(reversed(list(other['packages'].items())))
        self.assertEqual(workspace.pack_config(manifest), workspace.pack_config(other))

    def test_outside_paths_rejected(self):
        for path in ['/tmp/escape.ipkg', '../escape.ipkg']:
            with self.subTest(path=path), self.assertRaises(ValueError):
                workspace.pack_config({'collection': 'test', 'packages': {'bad': path}})

    def test_transitive_browser_boundary(self):
        with tempfile.TemporaryDirectory() as folder, patch.object(workspace, 'ROOT', Path(folder)):
            manifest = {'collection': 'test', 'packages': {'ui': 'ui.ipkg', 'bridge': 'bridge.ipkg', 'server': 'server.ipkg'},
                        'browser_roots': ['ui'], 'browser_forbidden': ['server']}
            (Path(folder) / 'pack.toml').write_text(workspace.pack_config(manifest))
            for name, depends in [('ui', 'bridge'), ('bridge', 'server'), ('server', 'base')]:
                (Path(folder) / f'{name}.ipkg').write_text(f'package {name}\ndepends = {depends}\n')
            with self.assertRaisesRegex(ValueError, 'browser dependency boundary'):
                workspace.check(manifest)

    def test_package_identity(self):
        with tempfile.TemporaryDirectory() as folder, patch.object(workspace, 'ROOT', Path(folder)):
            manifest = {'collection': 'test', 'packages': {'ui': 'ui.ipkg'}, 'browser_roots': [], 'browser_forbidden': []}
            (Path(folder) / 'pack.toml').write_text(workspace.pack_config(manifest))
            (Path(folder) / 'ui.ipkg').write_text('package something-else\n')
            with self.assertRaisesRegex(ValueError, 'identity mismatch'):
                workspace.check(manifest)


if __name__ == '__main__':
    unittest.main()
