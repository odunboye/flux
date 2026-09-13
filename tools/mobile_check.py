#!/usr/bin/env python3
"""Build/test the optional mobile package without changing workspace registrations."""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile
import workspace

ROOT = Path(__file__).resolve().parents[1]


def run(args, cwd=ROOT, timeout=300):
    command = [str(a) for a in args]
    process = subprocess.Popen(command, cwd=cwd, start_new_session=True)
    try:
        code = process.wait(timeout=timeout)
        if code:
            raise subprocess.CalledProcessError(code, command)
    except BaseException:
        workspace.stop_group(process)
        raise


def check(capacitor):
    capacitor = Path(capacitor).resolve(strict=True)
    if not (capacitor / 'js/bridge.mjs').is_file():
        raise ValueError('Use hardened idris2-capacitor >= 0.2.0')
    packages = {
        'capacitor': capacitor / 'capacitor.ipkg',
        'flux-ui': ROOT / 'packages/ui/flux-ui.ipkg',
        'flux-mobile': ROOT / 'packages/mobile/flux-mobile.ipkg',
        'flux-mobile-test': ROOT / 'packages/mobile/tests/test.ipkg',
    }
    collection = json.loads((ROOT / 'workspace.json').read_text())['collection']
    with tempfile.TemporaryDirectory(prefix='flux-mobile-check-') as directory:
        lines = ['collection = ' + json.dumps(collection)]
        for name, file in packages.items():
            lines += [f'[custom.all.{name}]', 'type = "local"',
                      'path = ' + json.dumps(str(file.parent)), 'ipkg = ' + json.dumps(file.name)]
        Path(directory, 'pack.toml').write_text('\n'.join(lines) + '\n')
        run(['pack', '--no-prompt', 'build', str(packages['flux-mobile-test'])], cwd=directory)
    run(['node', '--unhandled-rejections=strict', str(ROOT / 'packages/mobile/tests/runtime.mjs'),
         str(capacitor), str(ROOT / 'packages/mobile/tests/build/exec/flux-mobile-test.js')], timeout=30)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--capacitor', required=True, type=Path)
    check(parser.parse_args().capacitor)
