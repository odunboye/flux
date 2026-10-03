"""Persistence naming is an implementation move, not legacy namespace aliases."""
from pathlib import Path
import unittest
import workspace

ROOT = Path(__file__).resolve().parents[1]


class DBNamingTests(unittest.TestCase):
    def test_packages_and_boundaries(self):
        manifest = workspace.load()
        for old in ['nebula', 'nebula-flux', 'nebula-test', 'flux-db']:
            self.assertNotIn(old, manifest['packages'])
        # db moved out to its own repo (see design/CONSOLIDATION.md); it's a
        # pinned external dependency now, not a local package with its own
        # vendored source to scan.
        self.assertEqual(manifest['external_packages']['db']['ipkg'], 'db.ipkg')
        self.assertIn('db', manifest['browser_forbidden'])
        self.assertEqual(manifest['packages']['flux-db-flux'], 'packages/db-flux/flux-db-flux.ipkg')
        self.assertIn('flux-db-flux', manifest['browser_forbidden'])
        dbflux_text = (ROOT / manifest['packages']['flux-db-flux']).read_text()
        self.assertRegex(dbflux_text, r'(?m)^package flux-db-flux$')
        self.assertNotIn('Nebula.', dbflux_text)

    def test_owned_module_names(self):
        # db-flux is the genuinely Flux-specific glue (Flux.DB.PG/Flux.DB.Pool)
        # that stayed in this repo when db itself moved out and lost the
        # Flux.DB.* prefix - see design/CONSOLIDATION.md.
        source = ROOT / 'packages/db-flux/src'
        files = list(source.rglob('*.idr'))
        self.assertTrue(files)
        manifest = (source.parent / 'flux-db-flux.ipkg').read_text()
        for path in files:
            name = '.'.join(path.relative_to(source).with_suffix('').parts)
            with self.subTest(name=name):
                self.assertTrue(name.startswith('Flux.DB.'))
                self.assertIn('module ' + name + '\n', path.read_text())
                self.assertIn(name, manifest)
                self.assertNotRegex(path.read_text(), r'(?m)^import(?: public)? Nebula\.')


if __name__ == '__main__':
    unittest.main()
