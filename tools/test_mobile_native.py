import json
from pathlib import Path
import tempfile
import unittest
import mobile
import mobile_native


class NativeDependencyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.cap = self.root / 'cap'; self.host = self.root / 'host'; self.tooling = self.root / 'tooling'
        self.plugin = self.cap / 'native/session-vault'; self.plugin.mkdir(parents=True)
        self.host.mkdir(); self.tooling.mkdir()
        (self.plugin / 'package.json').write_text(json.dumps({'name': '@idris2/capacitor-session-vault', 'version': '0.1.0'}))
        (self.plugin / 'index.js').write_text('fixture')
        (self.tooling / 'package.json').write_text('{"dependencies":{"@capacitor/core":"8.4.3"}}')
        (self.tooling / 'package-lock.json').write_text('{}')
        self.calls = 0

    def run_npm(self, args, cwd):
        self.calls += 1
        self.assertEqual(args, ['npm', 'install', '--package-lock-only', '--ignore-scripts'])
        (cwd / 'package-lock.json').write_text('{"fixture":true}')

    def install(self):
        mobile_native.dependencies(self.host, self.cap, self.tooling, self.run_npm, mobile.inside, mobile.atomic_json)

    def test_owned_upgrade_and_repeat(self):
        for name in ['package.json', 'package-lock.json']:
            (self.host / name).write_bytes((self.tooling / name).read_bytes())
        self.install(); self.install(); self.assertEqual(self.calls, 1)
        package = json.loads((self.host / 'package.json').read_text())
        self.assertEqual(package['dependencies']['@idris2/capacitor-session-vault'], 'file:plugins/session-vault')
        (self.plugin / 'index.js').write_text('revision 2'); self.install(); self.assertEqual(self.calls, 2)
        self.assertEqual((self.host / 'plugins/session-vault/index.js').read_text(), 'revision 2')

    def test_unowned_or_modified_manifests_rejected(self):
        (self.host / 'package.json').write_text('{"unrelated":true}')
        with self.assertRaisesRegex(ValueError, 'Unowned'):
            self.install()
        (self.host / 'package.json').unlink(); self.install()
        (self.host / 'package-lock.json').write_text('edited')
        with self.assertRaisesRegex(ValueError, 'Modified'):
            self.install()

    def test_native_edits_symlinks_and_extra_source_rejected(self):
        self.install()
        extra = self.host / 'plugins/session-vault/extra.java'; extra.write_text('not ours')
        with self.assertRaisesRegex(ValueError, 'Unowned'):
            self.install()
        extra.unlink()
        target = self.host / 'plugins/session-vault/index.js'; target.unlink(); target.symlink_to(self.plugin / 'index.js')
        with self.assertRaisesRegex(ValueError, 'Symlink'):
            self.install()

    def test_source_changes_while_staging_do_not_publish(self):
        old = self.run_npm
        def mutate(args, cwd):
            old(args, cwd); (self.plugin / 'index.js').write_text('changed')
        self.run_npm = mutate
        with self.assertRaisesRegex(ValueError, 'changed during'):
            self.install()
        self.assertFalse((self.host / 'package.json').exists())

    def test_tooling_update_requires_new_managed_lock(self):
        self.install()
        (self.tooling / 'package-lock.json').write_text('{"updated":true}')
        self.install(); self.assertEqual(self.calls, 2)

    def test_corrupt_owner_cannot_adopt_other_files(self):
        (self.host / 'native-dependencies.json').write_text('{"format":1,"files":{}}')
        with self.assertRaisesRegex(ValueError, 'ownership'):
            self.install()


if __name__ == '__main__':
    unittest.main()
