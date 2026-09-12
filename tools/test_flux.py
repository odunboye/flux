import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import flux
import workspace


class FluxTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        original = flux.ROOT
        manifest = workspace.load()
        for path in set(manifest['packages'].values()) | {
                'workspace.json', 'pack.toml', 'platform/generate.py'} | {
                'platform/crud/' + name for name in flux.TEMPLATE_FILES}:
            target = self.root / path
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(original / path, target)
        for module in [flux, workspace]:
            patcher = patch.object(module, 'ROOT', self.root)
            patcher.start()
            self.addCleanup(patcher.stop)
        self.before = (self.root / 'workspace.json').read_bytes()

    def test_create_and_register(self):
        flux.new_project('sample')
        project, config = flux.project_config('apps/sample')
        flux.generate(project, config, check=True)
        manifest = workspace.load()
        self.assertIn('sample-ui', manifest['browser_roots'])
        self.assertEqual(manifest['packages']['sample-ui'], 'apps/sample/ui.ipkg')
        self.assertIn('package sample-server', (project / 'server.ipkg').read_text())
        workspace.check(manifest)

    def test_names_and_existing_directories_are_safe(self):
        for name in ['../escape', '/tmp/escape', 'Some App', '', 'x' * 49, 'todo-api', 'trailing-', 'two--hyphens']:
            with self.subTest(name=name), self.assertRaises(ValueError):
                flux.new_project(name)
        self.assertEqual((self.root / 'workspace.json').read_bytes(), self.before)

    def test_generation_failure_rolls_back(self):
        with patch.object(flux, 'generate', side_effect=RuntimeError('generation failed')):
            with self.assertRaisesRegex(RuntimeError, 'generation failed'):
                flux.new_project('broken')
        self.assertFalse((self.root / 'apps/broken').exists())
        self.assertEqual((self.root / 'workspace.json').read_bytes(), self.before)
        workspace.check(workspace.load())

    def test_map_failure_rolls_back(self):
        original = flux.atomic_write
        count = 0
        def fail_once(path, data):
            nonlocal count
            count += 1
            if count == 2:
                raise OSError('map failed')
            original(path, data)
        with patch.object(flux, 'atomic_write', side_effect=fail_once):
            with self.assertRaisesRegex(OSError, 'map failed'):
                flux.new_project('broken')
        self.assertFalse((self.root / 'apps/broken').exists())
        self.assertEqual((self.root / 'workspace.json').read_bytes(), self.before)
        workspace.check(workspace.load())

    def test_project_paths_cannot_escape(self):
        with self.assertRaises(ValueError):
            flux.project_config('../outside')
        path = self.root / 'platform/crud/flux.json'
        config = json.loads(path.read_text())
        config['schema'] = '../../workspace.json'
        path.write_text(json.dumps(config))
        with self.assertRaises(ValueError):
            flux.project_config('platform/crud')

    def test_subprocess_deadline(self):
        with self.assertRaises(subprocess.TimeoutExpired):
            flux.run([sys.executable, '-c', 'import time; time.sleep(30)'], timeout=.1)

    def test_database_requires_explicit_configuration(self):
        with patch.dict('os.environ', {}, clear=True):
            with self.assertRaisesRegex(ValueError, 'PGHOST'):
                with flux.database(False):
                    self.fail('should not supply a default database')


if __name__ == '__main__':
    unittest.main()
