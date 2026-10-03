"""Owned native plugin snapshots; no registry publication or application wiring."""
import hashlib
import json
from pathlib import Path
import shutil
import tempfile


def plugin_files(cap):
    root = cap / 'native/session-vault'
    if root.is_symlink() or root.parent.is_symlink():
        raise ValueError('Symlink in native plugin path')
    if not root.exists():
        return {}
    result = {}
    for file in sorted(root.rglob('*')):
        if file.is_symlink():
            raise ValueError('Symlink in native vault plugin')
        if file.is_file():
            name = file.relative_to(root).as_posix()
            if any(part.startswith('.') or part in ['build', 'node_modules'] for part in Path(name).parts):
                raise ValueError('Unexpected generated/private native plugin input')
            result['plugins/session-vault/' + name] = file.read_bytes()
    package = json.loads(result['plugins/session-vault/package.json'])
    if package.get('name') != '@idris2/capacitor-session-vault' or package.get('version') != '0.1.0':
        raise ValueError('Unsupported native vault plugin')
    return result


def dependencies(host, cap, tooling, run, inside, atomic_json):
    plugin = plugin_files(cap)
    if not plugin:
        for name in ['package.json', 'package-lock.json']:
            target = inside(host, name)
            expected = (tooling / name).read_bytes()
            if target.exists() and target.read_bytes() != expected:
                raise ValueError('Native host dependency files differ; refusing to overwrite ' + name)
            target.write_bytes(expected)
        return
    tooling_hash = hashlib.sha256((tooling / 'package.json').read_bytes() + (tooling / 'package-lock.json').read_bytes()).hexdigest()
    marker = inside(host, 'native-dependencies.json')
    if marker.exists():
        owned = json.loads(marker.read_text())
        if (owned.get('format') != 1 or not isinstance(owned.get('files'), dict) or
                not {'package.json', 'package-lock.json', 'plugins/session-vault/package.json'} <= set(owned['files']) or
                any(name not in ['package.json', 'package-lock.json'] and not name.startswith('plugins/session-vault/') for name in owned['files'])):
            raise ValueError('Invalid native dependency ownership')
        for name, fingerprint in owned['files'].items():
            file = inside(host, name)
            if not file.is_file() or hashlib.sha256(file.read_bytes()).hexdigest() != fingerprint:
                raise ValueError('Modified native dependency file: ' + name)
        existing = inside(host, 'plugins/session-vault')
        for file in existing.rglob('*'):
            relative = file.relative_to(existing)
            if relative.parts[:2] in [('android', 'build'), ('android', '.gradle')] or relative.parts[:1] == ('.build',):
                continue
            if file.is_symlink() or (file.is_file() and file.relative_to(host).as_posix() not in owned['files']):
                raise ValueError('Unowned native plugin file')
        if owned.get('tooling') == tooling_hash and all(inside(host, name).is_file() and inside(host, name).read_bytes() == data for name, data in plugin.items()) and set(plugin) == {n for n in owned['files'] if n.startswith('plugins/')}: 
            return
    else:
        # Only migrate the exact previous managed tooling manifests. Never adopt
        # arbitrary npm/application edits or an existing unowned plugin directory.
        for name in ['package.json', 'package-lock.json']:
            file = inside(host, name)
            if file.exists() and file.read_bytes() != (tooling / name).read_bytes():
                raise ValueError('Unowned native dependency manifest')
        if inside(host, 'plugins').exists():
            raise ValueError('Unowned native plugins directory')
    with tempfile.TemporaryDirectory(prefix='dependency-stage-', dir=host) as temporary:
        stage = Path(temporary)
        package = json.loads((tooling / 'package.json').read_text())
        package['dependencies']['@idris2/capacitor-session-vault'] = 'file:plugins/session-vault'
        (stage / 'package.json').write_text(json.dumps(package, indent=2) + '\n')
        (stage / 'package-lock.json').write_bytes((tooling / 'package-lock.json').read_bytes())
        for name, data in plugin.items():
            file = stage / name; file.parent.mkdir(parents=True, exist_ok=True); file.write_bytes(data)
        run(['npm', 'install', '--package-lock-only', '--ignore-scripts'], stage)
        files = dict(plugin, **{name: (stage / name).read_bytes() for name in ['package.json', 'package-lock.json']})
        if plugin_files(cap) != plugin:
            raise ValueError('Native plugin inputs changed during dependency staging')
        target = inside(host, 'plugins/session-vault')
        if target.exists():
            shutil.rmtree(target)
        for name, data in files.items():
            file = inside(host, name); file.parent.mkdir(parents=True, exist_ok=True); file.write_bytes(data)
        atomic_json(marker, {'format': 1, 'tooling': tooling_hash, 'files': {name: hashlib.sha256(data).hexdigest() for name, data in files.items()}})
