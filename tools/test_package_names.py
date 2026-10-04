"""Canonical platform package identities, without old-name alias packages.

postgres/postgres-async/db/docker/runtime/iris/iris-client are deliberately
NOT in RENAMES: unlike the other imported packages, each was moved back out
to its own external repo (see workspace.json's external_packages and
design/CONSOLIDATION.md), so its current name there is the correct one - not
a legacy alias to guard against.
"""
from pathlib import Path
import unittest
import workspace

ROOT = Path(__file__).resolve().parents[1]
RENAMES = {
    'flux-platform': ('flux-protocol', 'platform/flux-protocol.ipkg'),
}


class PackageNamingTests(unittest.TestCase):
    def test_canonical_names_and_files(self):
        manifest = workspace.load()
        for old, (new, file) in RENAMES.items():
            with self.subTest(package=new):
                self.assertNotIn(old, manifest['packages'])
                self.assertEqual(manifest['packages'][new], file)
                self.assertRegex((ROOT / file).read_text(), rf'(?m)^package {new}$')
                self.assertFalse((ROOT / file).with_name(old + '.ipkg').exists())
        for old in ['idris2-docker', 'flux-docker', 'flux-runtime', 'flux-async', 'flux-ui', 'flux-ui-todo',
                    'flux-platform-client', 'flux-client']:
            self.assertNotIn(old, manifest['packages'])
        self.assertIn('platform-crud-ui', manifest['browser_roots'])
        self.assertNotIn('flux-ui', manifest['browser_roots'])
        self.assertNotIn('flux-client', manifest['browser_roots'])
        for forbidden in ['runtime', 'flux-protocol', 'postgres', 'postgres-async', 'db']:
            self.assertIn(forbidden, manifest['browser_forbidden'])

    def test_all_package_dependencies_use_current_names(self):
        for file in ROOT.rglob('*.ipkg'):
            if any(part in {'build', '.git', '.workspace', 'node_modules', 'reports'} for part in file.relative_to(ROOT).parts):
                continue
            with self.subTest(file=str(file.relative_to(ROOT))):
                self.assertFalse(workspace.dependencies(file.read_text()).intersection(RENAMES))


if __name__ == '__main__':
    unittest.main()
