"""Persistence naming is an implementation move, not legacy namespace aliases."""
from pathlib import Path
import re
import unittest
import workspace

ROOT = Path(__file__).resolve().parents[1]


class DBNamingTests(unittest.TestCase):
    def test_packages_and_boundaries(self):
        manifest = workspace.load()
        for old in ['nebula', 'nebula-flux', 'nebula-test']:
            self.assertNotIn(old, manifest['packages'])
        for name, directory in [('flux-db', 'db'), ('flux-db-flux', 'db-flux')]:
            self.assertEqual(manifest['packages'][name], f'packages/{directory}/{name}.ipkg')
            self.assertIn(name, manifest['browser_forbidden'])
            text = (ROOT / manifest['packages'][name]).read_text()
            self.assertRegex(text, rf'(?m)^package {name}$')
            self.assertNotIn('Nebula.', text)

    def test_owned_module_names(self):
        for directory, package in [('db', 'flux-db'), ('db-flux', 'flux-db-flux')]:
            source = ROOT / f'packages/{directory}/src'
            files = list(source.rglob('*.idr'))
            self.assertTrue(files)
            manifest = (source.parent / f'{package}.ipkg').read_text()
            for path in files:
                name = '.'.join(path.relative_to(source).with_suffix('').parts)
                with self.subTest(name=name):
                    self.assertTrue(name.startswith('Flux.DB.'))
                    self.assertIn('module ' + name + '\n', path.read_text())
                    self.assertIn(name, manifest)
                    self.assertNotRegex(path.read_text(), r'(?m)^import(?: public)? (?:Nebula\.|Data\.PG(?:Migration|Repository|Crud|Field|Row|Table|Query|ColumnType)\b|Derive\.PGActiveRecord\b|ObjectFromJSON\b)')

    def test_legacy_metadata_is_a_guard_not_a_fallback(self):
        text = (ROOT / 'packages/db/src/Flux/DB/Migration.idr').read_text()
        self.assertIn("nspname = 'nebula_meta'", text)
        self.assertNotIn('nebula_meta.migrations', text)
        self.assertIn('INSERT INTO flux_db_meta.migrations', text)
        self.assertIn('pg_try_advisory_lock(723946218534101)', text)
        self.assertLess(text.index('prepareMetadata db |'), text.index('SELECT version, name, checksum'))


if __name__ == '__main__':
    unittest.main()
