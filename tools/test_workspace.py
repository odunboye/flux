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
        self.assertEqual(workspace.dependencies('package x\ndepends = flux-ui -- comment\n  , json-simple\nmodules = X\n'), {'flux-ui', 'json-simple'})

    def test_version_qualified_dependency_parser(self):
        source = '''package example
          depends = flux-ui >= 0.1.0 && < 1.0.0 -- retained as flux-ui
                  , json-simple==0.1.0
                  , server
                    >= 0.1.0
                    && < 2.0.0
          modules = Example
        '''
        self.assertEqual(workspace.dependencies(source), {'flux-ui', 'json-simple', 'server'})
        self.assertEqual(workspace.dependencies('package x\nmodules = X\n'), set())
        self.assertEqual(workspace.dependencies('depends =\n  modules = X\n'), set())
        self.assertEqual(workspace.dependencies('depends =\nserver == 0.1.0\nmodules = X\n'), {'server'})
        self.assertEqual(workspace.dependencies('depends = flux-ui,\nserver == 0.1.0\nmain = Main\n'), {'flux-ui', 'server'})

    def test_unknown_dependency_syntax_fails_closed(self):
        with self.assertRaisesRegex(ValueError, 'cannot parse dependency name'):
            workspace.dependencies('depends = "server" >= 0.1.0\n')
        with self.assertRaisesRegex(ValueError, 'multiple depends'):
            workspace.dependencies('depends = flux-ui\ndepends = server >= 0.1.0\n')

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

    def test_version_qualified_browser_boundaries(self):
        bounds = ['', ' >= 0.1.0', '>=0.1.0', ' == 0.1.0', ' >= 0.1.0 && < 2.0.0',
                  '\n  >= 0.1.0\n  && <= 2.0.0']
        for bound in bounds:
            for transitive in [False, True]:
                with self.subTest(bound=bound, transitive=transitive), tempfile.TemporaryDirectory() as folder:
                    with patch.object(workspace, 'ROOT', Path(folder)):
                        manifest = {'collection': 'test', 'packages': {
                            'ui': 'ui.ipkg', 'bridge': 'bridge.ipkg', 'server': 'server.ipkg'},
                            'browser_roots': ['ui'], 'browser_forbidden': ['server']}
                        (Path(folder) / 'pack.toml').write_text(workspace.pack_config(manifest))
                        edges = {'ui': ('bridge' if transitive else 'server') + bound,
                                 'bridge': 'server' + bound, 'server': 'base'}
                        for name, deps in edges.items():
                            (Path(folder) / f'{name}.ipkg').write_text(f'package {name}\ndepends = {deps}\n')
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
