"""External-project configuration, generation, assets and artifact regression tests."""
import contextlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import application
import flux
import devwatch


class ApplicationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='external-flux-app-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        (self.root / 'src').mkdir()
        (self.root / 'api').mkdir()
        (self.root / 'public/assets').mkdir(parents=True)
        (self.root / 'public/index.html').write_text('<html><head></head><body></body></html>')
        (self.root / 'public/app.css').write_text('@import url("extra.css");')
        (self.root / 'public/extra.css').write_text('body{color:black}')
        (self.root / 'public/assets/icon.png').write_bytes(b'fixture-image')
        for target in ['ui', 'server']:
            (self.root / (target + '.ipkg')).write_text('package external-' + target + '\n' +
                'depends = ' + ('flux-client, iris' if target == 'ui' else 'flux-protocol, flux-auth') +
                '\nsourcedir = "src"\nmodules = Main\nmain = Main\nexecutable = external-' + target + '\n')
        shutil.copyfile(flux.ROOT / 'platform/crud/schema.json', self.root / 'api/schema.json')
        self.cfg = {'format': 2, 'schema': 'api/schema.json', 'server': 'server.ipkg', 'ui': 'ui.ipkg',
                    'sources': ['src'], 'generated': {'directory': 'src/Generated', 'namespace': 'Generated', 'openapi': 'api/openapi.json'},
                    'public': {'directory': 'public', 'files': ['index.html', '*.css', 'assets/*.png']},
                    'dependencies': 'managed', 'database': 'none', 'run': {'web': True}}
        self.save()

    def save(self):
        (self.root / 'flux.json').write_text(json.dumps(self.cfg))

    @contextlib.contextmanager
    def cwd(self, path):
        before = Path.cwd(); os.chdir(path)
        try: yield
        finally: os.chdir(before)

    def fake_build(self):
        path = self.root / 'build/exec/external-server_app/external-server.so'
        path.parent.mkdir(parents=True)
        path.write_bytes(b'fake native')
        (self.root / 'build/exec/external-ui').write_bytes(b'const application = 1;')

    def test_external_discovery_and_explicit_paths(self):
        with self.cwd(self.root / 'src'):
            self.assertEqual(flux.project_config()[0], self.root)
            self.assertEqual(flux.project_config('../flux.json')[0], self.root)
        self.assertEqual(flux.project_config(self.root)[1], self.cfg)
        with self.cwd(self.root):
            with patch.object(flux, 'run'), patch('sys.argv', ['flux', 'sync']):
                flux.main()
            with patch.object(flux, 'generate') as generate, patch('sys.argv', ['flux', 'generate', '--project', str(self.root)]):
                flux.main()
            generate.assert_called_once()

    def test_generated_namespace_and_dependency_map_do_not_mutate_framework(self):
        before = (flux.ROOT / 'workspace.json').read_bytes(), (flux.ROOT / 'pack.toml').read_bytes()
        expected = application.pack_config(self.root, self.cfg, flux.ROOT)
        (self.root / 'pack.toml').write_text(expected)
        application.check_dependencies(self.root, self.cfg, flux.ROOT)
        flux.generate(self.root, self.cfg)
        flux.generate(self.root, self.cfg, check=True)
        client = (self.root / 'src/Generated/Client.idr').read_text()
        self.assertIn('module Generated.Client', client)
        self.assertIn('import public Generated.ProtocolTypes', client)
        original = json.loads((self.root / 'api/schema.json').read_text())
        self.assertEqual(original, json.loads((flux.ROOT / 'platform/crud/schema.json').read_text()))
        self.assertTrue((self.root / 'api/openapi.json').is_file())
        self.assertEqual(before, ((flux.ROOT / 'workspace.json').read_bytes(), (flux.ROOT / 'pack.toml').read_bytes()))
        (self.root / 'pack.toml').write_text('stale')
        with self.assertRaisesRegex(ValueError, 'flux sync'):
            application.check_dependencies(self.root, self.cfg, flux.ROOT)

    def test_legacy_config_still_loads(self):
        old = {key: self.cfg[key] for key in application.BASE_KEYS}
        old['format'] = 1
        (self.root / 'flux.json').write_text(json.dumps(old))
        self.assertEqual(application.load(self.root), old)

    def test_config_escape_unknown_fields_and_source_coverage_rejected(self):
        for key, value in [('schema', '../escape.json'), ('ui', '/absolute.ipkg'), ('format', True)]:
            changed = dict(self.cfg, **{key: value})
            (self.root / 'flux.json').write_text(json.dumps(changed))
            with self.assertRaises(ValueError): application.load(self.root)
        changed = dict(self.cfg, nonsense=True)
        (self.root / 'flux.json').write_text(json.dumps(changed))
        with self.assertRaises(ValueError): application.load(self.root)
        self.cfg['generated']['openapi'] = 'api/schema.json'; self.save()
        with self.assertRaises(ValueError): application.load(self.root)
        self.cfg['generated']['openapi'] = 'api/openapi.json'
        self.cfg['generated']['namespace'] = 'Generated; import Evil'; self.save()
        with self.assertRaises(ValueError): application.load(self.root)
        self.cfg['generated']['namespace'] = 'Generated'
        self.cfg['sources'] = ['api']; self.save()
        with self.assertRaisesRegex(ValueError, 'sourcedir'): application.load(self.root)

    def test_public_allowlist_rejects_private_files_and_symlinks(self):
        self.assertEqual(set(application.public_files(self.root, self.cfg)), {'index.html', 'app.css', 'extra.css', 'assets/icon.png'})
        (self.root / 'public/private.idr').write_text('private source')
        self.cfg['public']['files'].append('*')
        with self.assertRaisesRegex(ValueError, 'public web asset'):
            application.public_files(self.root, self.cfg)
        self.cfg['public']['files'].pop()
        (self.root / 'public/assets/leak.png').symlink_to(self.root / 'api/schema.json')
        with self.assertRaisesRegex(ValueError, 'symlinks'):
            application.public_files(self.root, self.cfg)

    def test_immutable_release_and_native_run_do_not_build_or_proxy(self):
        self.fake_build()
        release = application.release(self.root, self.cfg, flux.atomic_write)
        directory, cfg = application.built_release(self.root, self.cfg)
        self.assertEqual(directory, release)
        self.assertTrue((release / '.public/assets/icon.png').exists())
        self.assertFalse((release / '.public/src').exists())
        self.assertNotIn(b'/__flux_dev/', (release / '.public/index.html').read_bytes())
        # Source edits do not mutate the built artifact.
        (self.root / 'public/extra.css').write_text('changed source')
        self.assertEqual((release / '.public/extra.css').read_text(), 'body{color:black}')
        with patch.object(flux, 'run_application') as native, patch.object(flux, 'dev') as dev, \
             patch.object(flux, 'build') as build, patch('sys.argv', ['flux', 'run', '--project', str(self.root)]):
            flux.main()
        native.assert_called_once(); dev.assert_not_called(); build.assert_not_called()
        (release / '.public/app.js').write_text('tampered')
        with self.assertRaisesRegex(ValueError, 'artifact changed'):
            application.built_release(self.root, self.cfg)

    def test_failed_release_leaves_previous_pointer(self):
        self.fake_build()
        application.release(self.root, self.cfg, flux.atomic_write)
        old = (self.root / '.workspace/application.json').read_bytes()
        (self.root / 'build/exec/external-ui').unlink()
        with self.assertRaises(ValueError): application.release(self.root, self.cfg, flux.atomic_write)
        self.assertEqual((self.root / '.workspace/application.json').read_bytes(), old)

    def test_staging_serves_only_selected_assets_and_is_cleaned(self):
        self.fake_build()
        with flux.staging_session() as stage:
            directory, cfg = stage(self.root, self.cfg)
            snapshot = devwatch.asset_snapshot(directory, cfg)
            self.assertIn('/extra.css', snapshot)
            self.assertIn('/assets/icon.png', snapshot)
            self.assertNotIn('/api/schema.json', snapshot)
            self.assertNotIn('/flux.json', snapshot)
            self.assertNotIn('/server.ipkg', snapshot)
            self.assertIn('@import', snapshot['/app.css'][0].decode())
        self.assertFalse(directory.exists())

    def test_browser_boundary_applies_to_external_projects(self):
        (self.root / 'ui.ipkg').write_text('package external-ui\ndepends = flux-auth\n')
        with self.assertRaisesRegex(ValueError, 'server-only'):
            application.package_graph(self.root, self.cfg, flux.ROOT)

    def test_docker_unavailable_does_not_claim_or_remove_uncreated_database(self):
        error = subprocess.CalledProcessError(1, ['docker', 'info'], stderr='cannot connect to Docker')
        with patch.object(flux, 'run', side_effect=error) as run:
            with self.assertRaisesRegex(RuntimeError, 'Docker daemon unavailable before database startup'):
                with flux.database(True): self.fail('database must not become available')
        self.assertEqual(run.call_count, 1)
        self.assertEqual(run.call_args.args[0][1], 'info')

    def test_duplicate_keys_and_incomplete_artifact_manifest_rejected(self):
        (self.root / 'flux.json').write_text('{"format":2,"format":1}')
        with self.assertRaisesRegex(ValueError, 'Duplicate'):
            application.load(self.root)
        self.save(); self.fake_build()
        application.release(self.root, self.cfg, flux.atomic_write)
        path = self.root / '.workspace/application.json'
        data = json.loads(path.read_text()); data['hashes'] = {}
        path.write_text(json.dumps(data))
        with self.assertRaisesRegex(ValueError, 'build manifest'):
            application.built_release(self.root, self.cfg)

    def test_cli_installer_cannot_replace_itself_and_restores_on_failure(self):
        with patch.object(flux, 'atomic_write') as write:
            flux.install_cli(flux.ROOT, force=True)
            write.assert_not_called()
        directory = self.root / 'bin'; directory.mkdir()
        target = directory / 'flux'; target.write_text('old launcher')
        with patch.object(flux, 'atomic_write', side_effect=OSError('disk full')):
            with self.assertRaises(OSError): flux.install_cli(directory, force=True)
        self.assertEqual(target.read_text(), 'old launcher')

    def test_cli_installer_refuses_overwrite_unless_backed_up(self):
        directory = self.root / 'bin'; directory.mkdir()
        old = directory / 'flux'; old.write_text('old launcher')
        with self.assertRaisesRegex(ValueError, 'different flux'):
            flux.install_cli(directory)
        flux.install_cli(directory, force=True)
        self.assertEqual(next(directory.glob('flux.backup-*')).read_text(), 'old launcher')
        self.assertTrue(os.access(old, os.X_OK))
        self.assertIn(str(flux.ROOT / 'flux'), old.read_text())


if __name__ == '__main__':
    unittest.main()
