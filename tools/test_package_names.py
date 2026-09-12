"""Canonical platform package identities, without old-name alias packages."""
from pathlib import Path
import unittest
import workspace

ROOT = Path(__file__).resolve().parents[1]
RENAMES = {
    'flux-async': ('flux-runtime', 'packages/runtime/flux-runtime.ipkg'),
    'flux-platform': ('flux-protocol', 'platform/flux-protocol.ipkg'),
    'flux-platform-client': ('flux-client', 'platform/flux-client.ipkg'),
    'idris2-pg': ('flux-postgres', 'packages/postgres/flux-postgres.ipkg'),
    'idris2-pg-async': ('flux-postgres-pool', 'packages/postgres/async/flux-postgres-pool.ipkg'),
    'idris2-docker': ('flux-docker', 'packages/docker/flux-docker.ipkg'),
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
        self.assertIn('flux-client', manifest['browser_roots'])
        for forbidden in ['flux-runtime', 'flux-protocol', 'flux-postgres', 'flux-postgres-pool']:
            self.assertIn(forbidden, manifest['browser_forbidden'])

    def test_all_package_dependencies_use_current_names(self):
        for file in ROOT.rglob('*.ipkg'):
            if any(part in {'build', '.git', '.workspace', 'node_modules', 'reports'} for part in file.relative_to(ROOT).parts):
                continue
            with self.subTest(file=str(file.relative_to(ROOT))):
                self.assertFalse(workspace.dependencies(file.read_text()).intersection(RENAMES))


if __name__ == '__main__':
    unittest.main()
