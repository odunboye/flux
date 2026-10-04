import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import mobile


class MobileTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.cap = self.root / 'capacitor'
        (self.cap / 'js').mkdir(parents=True)
        (self.cap / 'node_modules/@capacitor/core').mkdir(parents=True)
        (self.cap / 'package.json').write_text('{"version":"0.2.0"}')
        (self.cap / 'package-lock.json').write_text('{}')
        (self.cap / 'js/bridge.mjs').write_text('export const fixture = true;')
        (self.cap / 'js/register.mjs').write_text('globalThis.mobileFixture = true;')
        self.project = self.root / 'app'
        self.web = self.project / 'public'
        self.web.mkdir(parents=True)
        (self.web / 'index.html').write_text('<main>fixture</main><script src="app.js"></script>')
        (self.web / 'app.css').write_text('body{color:black}')
        (self.project / 'application.js').write_text('globalThis.applicationFixture = true;')
        self.cfg = {'format': 1, 'appId': 'com.example.fixture', 'appName': 'Fixture',
                    'capacitor': '../capacitor', 'webDir': 'public', 'entry': 'application.js',
                    'assets': ['index.html', '*.css']}
        self.save()

    def save(self):
        (self.project / 'flux.mobile.json').write_text(json.dumps(self.cfg))

    def test_build_and_verify_module_bundle(self):
        release = mobile.build(self.project)
        self.assertIn('type="module"', (release / 'index.html').read_text())
        self.assertIn('mobileFixture', (release / 'app.js').read_text())
        self.assertEqual(mobile.built(self.project)[2], release)
        self.assertFalse((self.project / 'node_modules').exists())

    def test_format_two_config_precedes_application_and_binds_csp(self):
        from test_mobile_policy import HTML
        self.cfg.update(format=2, apiOrigin='https://api.example.test'); self.save()
        (self.web / 'index.html').write_text(HTML)
        (self.project / 'application.js').write_text('if(globalThis.FluxMobile.apiOrigin!=="https://api.example.test" || !globalThis.FluxMobileTransport) throw Error("configuration order");')
        release = mobile.build(self.project)
        subprocess.run(['node', str(release / 'app.js')], check=True, timeout=10)
        self.assertIn('connect-src https://api.example.test', (release / 'index.html').read_text())
        self.assertEqual(mobile.built(self.project)[2], release)

    def test_format_two_requires_explicit_secure_configuration(self):
        self.cfg.update(format=2, apiOrigin='http://localhost:8080'); self.save()
        with self.assertRaisesRegex(ValueError, 'HTTPS'):
            mobile.build(self.project)
        self.cfg['apiOrigin'] = 'https://api.example.test'; self.save()
        with self.assertRaisesRegex(ValueError, 'CSP'):
            mobile.build(self.project)

    def test_failed_build_preserves_last_good(self):
        mobile.build(self.project)
        manifest = self.project / '.workspace/mobile/build.json'
        previous = manifest.read_bytes()
        (self.project / 'application.js').write_text('not valid javascript !')
        with self.assertRaises(subprocess.CalledProcessError):
            mobile.build(self.project)
        self.assertEqual(manifest.read_bytes(), previous)
        self.assertEqual(list((self.project / '.workspace/mobile').glob('stage-*')), [])

    def test_stale_source_and_output_tampering_rejected(self):
        release = mobile.build(self.project)
        (self.web / 'app.css').write_text('changed')
        with self.assertRaisesRegex(ValueError, 'stale'):
            mobile.built(self.project)
        (self.web / 'app.css').write_text('body{color:black}')
        (release / 'app.js').write_text('tampered')
        with self.assertRaisesRegex(ValueError, 'integrity'):
            mobile.built(self.project)

    def test_native_plugin_sources_invalidate_a_bundle(self):
        plugin = self.cap / 'native/session-vault'; plugin.mkdir(parents=True)
        (plugin / 'package.json').write_text(json.dumps({'name': '@idris2/capacitor-session-vault', 'version': '0.1.0'}))
        (plugin / 'Vault.swift').write_text('first revision')
        mobile.build(self.project)
        (plugin / 'Vault.swift').write_text('second revision')
        with self.assertRaisesRegex(ValueError, 'stale'):
            mobile.built(self.project)

    def test_directory_symlink_cannot_escape_release(self):
        release = mobile.build(self.project)
        (release / 'outside').symlink_to(self.cap, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, 'Symlinks'):
            mobile.built(self.project)

    def test_public_symlinks_and_private_assets_rejected(self):
        (self.web / 'app.css').unlink()
        (self.web / 'app.css').symlink_to(self.cap / 'package.json')
        with self.assertRaisesRegex(ValueError, 'Symlinks'):
            mobile.build(self.project)
        (self.web / 'app.css').unlink()
        (self.web / 'private.json').write_text('{"secret":"fixture"}')
        self.cfg['assets'].append('*.json'); self.save()
        with self.assertRaisesRegex(ValueError, 'Only public'):
            mobile.build(self.project)

    def test_configuration_validation(self):
        for key, value in [('format', True), ('entry', '../outside.js'), ('assets', ['../*']), ('appId', 'bad'), ('unknown', True)]:
            original = self.cfg.copy(); self.cfg[key] = value; self.save()
            with self.assertRaises(ValueError):
                mobile.build(self.project)
            self.cfg = original
        (self.project / 'flux.mobile.json').write_text('{"format":1,"format":1}')
        with self.assertRaisesRegex(ValueError, 'Duplicate'):
            mobile.build(self.project)

    def test_unknown_workspace_is_not_overwritten(self):
        directory = self.project / '.workspace/mobile'; directory.mkdir(parents=True)
        private = directory / 'keep.txt'; private.write_text('keep')
        with self.assertRaisesRegex(ValueError, 'unowned'):
            mobile.build(self.project)
        self.assertEqual(private.read_text(), 'keep')

    def test_unknown_native_host_is_not_overwritten(self):
        mobile.build(self.project)
        host = self.project / '.workspace/mobile/native'; host.mkdir()
        with self.assertRaisesRegex(ValueError, 'unowned native'):
            mobile.sync(self.project, 'ios')
        self.assertEqual(list(host.iterdir()), [])

    def test_native_sync_is_explicit_and_preserves_identity(self):
        mobile.build(self.project)
        with patch.object(mobile, 'run') as run:
            host, cli = mobile.sync(self.project, 'android')
            self.assertEqual(run.call_count, 3)  # npm ci, cap add, cap sync
            self.assertEqual(run.call_args.args[0][-2:], ['sync', 'android'])
        self.assertEqual(json.loads((host / 'capacitor.config.json').read_text())['webDir'], 'www')
        self.assertEqual(json.loads((host / 'capacitor.config.json').read_text())['loggingBehavior'], 'none')
        self.cfg['appId'] = 'com.example.other'; self.save(); mobile.build(self.project)
        with patch.object(mobile, 'run') as run:
            with self.assertRaisesRegex(ValueError, 'identity'):
                mobile.sync(self.project, 'android')
            run.assert_not_called()
        self.assertEqual(json.loads((host / 'capacitor.config.json').read_text())['appId'], 'com.example.fixture')

    def test_project_lock_rejects_concurrent_native_operations(self):
        with mobile.exclusive(self.project):
            with self.assertRaisesRegex(ValueError, 'Another mobile'):
                with mobile.exclusive(self.project):
                    self.fail('second owner acquired lock')
        with mobile.exclusive(self.project):
            pass

    def test_failed_native_asset_copy_preserves_previous_tree(self):
        mobile.build(self.project)
        with patch.object(mobile, 'run'):
            host, _ = mobile.sync(self.project, 'ios')
        old = (host / 'www/app.js').read_bytes()
        with patch.object(mobile.shutil, 'copytree', side_effect=OSError('copy failed')):
            with self.assertRaisesRegex(OSError, 'copy failed'):
                mobile.sync(self.project, 'ios')
        self.assertEqual((host / 'www/app.js').read_bytes(), old)
        self.assertEqual(list(host.glob('web-stage-*')), [])

    def test_compile_uses_temporary_optional_map(self):
        self.cfg['ui'] = 'mobile.ipkg'; self.save()
        (self.project / 'application.js').unlink()
        (self.project / 'mobile.ipkg').write_text('package fixture\n')
        original = 'collection="nightly-260903"\n[custom.all.fixture]\ntype="local"\npath="."\nipkg="mobile.ipkg"\n'
        (self.project / 'pack.toml').write_text(original)
        locations = []
        def run(args, cwd):
            locations.append(Path(cwd))
            contents = (Path(cwd) / 'pack.toml').read_text()
            self.assertIn('[custom.all.iris-mobile]', contents)
            self.assertIn(str(self.cap), contents)
            self.assertIn('--cg', args)
        with patch.object(mobile, 'run', side_effect=run):
            mobile.compile_ui(self.project)
        self.assertFalse(locations[0].exists())
        self.assertEqual((self.project / 'pack.toml').read_text(), original)

    def test_tool_timeout_stops_owned_process_group(self):
        with patch.object(mobile.mobile_check.subprocess, 'Popen') as popen, \
             patch.object(mobile.mobile_check.workspace, 'stop_group') as stop:
            process = popen.return_value
            process.wait.side_effect = subprocess.TimeoutExpired(['fixture'], 300)
            with self.assertRaises(subprocess.TimeoutExpired):
                mobile.run(['fixture'], self.project)
            self.assertTrue(popen.call_args.kwargs['start_new_session'])
            stop.assert_called_once_with(process)

    def test_tool_interrupt_stops_owned_process_group(self):
        with patch.object(mobile.mobile_check.subprocess, 'Popen') as popen, \
             patch.object(mobile.mobile_check.workspace, 'stop_group') as stop:
            process = popen.return_value
            process.wait.side_effect = KeyboardInterrupt()
            with self.assertRaises(KeyboardInterrupt):
                mobile.run(['fixture'], self.project)
            stop.assert_called_once_with(process)

    def test_dispatch_does_not_intercept_normal_commands(self):
        with patch.object(mobile, 'main') as main:
            self.assertFalse(mobile.dispatch(['build']))
            self.assertTrue(mobile.dispatch(['--project', '/app', 'mobile', 'build']))
            main.assert_called_once_with(['--project', '/app', 'build'])
            main.reset_mock()
            self.assertTrue(mobile.dispatch(['--project=/app', 'mobile', 'build']))
            main.assert_called_once_with(['--project=/app', 'build'])


if __name__ == '__main__':
    unittest.main()
