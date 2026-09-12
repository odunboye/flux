"""The UI rename is a source/ABI cutover, not a facade over legacy modules."""
from pathlib import Path
import re
import unittest
import workspace

ROOT = Path(__file__).resolve().parents[1]


class UINamingTests(unittest.TestCase):
    def test_canonical_package_only(self):
        manifest = workspace.load()
        self.assertNotIn('iris', manifest['packages'])
        self.assertEqual(manifest['packages']['flux-ui'], 'packages/ui/flux-ui.ipkg')
        self.assertIn('flux-ui', manifest['browser_roots'])
        self.assertFalse((ROOT / 'packages/ui/iris.ipkg').exists())
        self.assertFalse((ROOT / 'packages/ui/src/Iris').exists())
        self.assertFalse((ROOT / 'packages/ui/compat').exists())
        text = (ROOT / 'packages/ui/flux-ui.ipkg').read_text()
        self.assertNotIn('Iris.', text)
        self.assertRegex(text, r'(?m)^package flux-ui$')

    def test_modules_are_definitions_not_aliases(self):
        source = ROOT / 'packages/ui/src'
        files = list((source / 'Flux').rglob('*.idr'))
        manifest = (ROOT / 'packages/ui/flux-ui.ipkg').read_text()
        declared = re.findall(r'(?m)^\s*,?\s*(Flux\.UI(?:\.[A-Za-z][A-Za-z0-9_]*)*)\s*$', manifest)
        actual = {'.'.join(path.relative_to(source).with_suffix('').parts) for path in files}
        self.assertIn('Flux.UI', actual)
        self.assertEqual(set(declared), actual)
        self.assertEqual(len(declared), len(files), 'duplicate public module declarations')
        for path in files:
            name = '.'.join(path.relative_to(source).with_suffix('').parts)
            with self.subTest(name=name):
                self.assertIn('module ' + name + '\n', path.read_text())
        self.assertIn('record UIApp', (source / 'Flux/UI/App.idr').read_text())
        self.assertIn('data UIColor', (source / 'Flux/UI/Widget.idr').read_text())

    def test_runtime_identifiers_are_renamed(self):
        old = re.compile(r'Iris\.|\bIrisApp\b|\bIrisColor\b|__iris|iris_tui_|iristui|data-iris-|iris-app|\bi1\b')
        for folder in ['packages/ui/src', 'packages/ui/c', 'platform/client/src', 'platform/crud']:
            for path in (ROOT / folder).rglob('*'):
                if 'build' in path.parts or path.suffix not in {'.idr', '.c', '.html', '.css'}:
                    continue
                with self.subTest(path=str(path.relative_to(ROOT))):
                    self.assertIsNone(old.search(path.read_text()))
        self.assertIn('wireVersion = "f1"', (ROOT / 'packages/ui/src/Flux/UI/App/EventWire.idr').read_text())
        self.assertIn('flux_ui_tui_raw_on', (ROOT / 'packages/ui/c/fluxuitui.c').read_text())


if __name__ == '__main__':
    unittest.main()
