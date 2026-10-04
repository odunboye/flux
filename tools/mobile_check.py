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
        raise ValueError('Use hardened capacitor >= 0.2.0')
    manifest = json.loads((ROOT / 'workspace.json').read_text())
    collection = manifest['collection']
    iris = manifest['external_packages']['iris']
    with tempfile.TemporaryDirectory(prefix='flux-mobile-check-') as directory:
        directory = Path(directory)
        iris_clone = directory / 'iris'
        run(['git', 'clone', '--quiet', iris['url'], str(iris_clone)], cwd=directory, timeout=120)
        run(['git', 'checkout', '--quiet', iris['commit']], cwd=iris_clone, timeout=60)
        packages = {
            'capacitor': capacitor / 'capacitor.ipkg',
            'iris': iris_clone / iris['ipkg'],
            'iris-client': iris_clone / 'client/iris-client.ipkg',
            'iris-mobile': iris_clone / 'mobile/iris-mobile.ipkg',
            'iris-mobile-test': iris_clone / 'mobile/tests/test.ipkg',
        }
        lines = ['collection = ' + json.dumps(collection)]
        for name, file in packages.items():
            lines += [f'[custom.all.{name}]', 'type = "local"',
                      'path = ' + json.dumps(str(file.parent)), 'ipkg = ' + json.dumps(file.name)]
        Path(directory, 'pack.toml').write_text('\n'.join(lines) + '\n')
        run(['pack', '--no-prompt', 'build', str(packages['iris-mobile-test'])], cwd=directory)
        run(['node', '--unhandled-rejections=strict', str(iris_clone / 'mobile/tests/runtime.mjs'),
             str(capacitor), str(iris_clone / 'mobile/tests/build/exec/iris-mobile-test.js')], timeout=30)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--capacitor', required=True, type=Path)
    check(parser.parse_args().capacitor)
