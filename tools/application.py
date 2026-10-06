"""Validated application layouts and build artifacts shared by the Flux CLI.

No application-specific callbacks, namespace rewrites or asset transformations.
Only explicitly selected public files can enter a served directory.
"""
import hashlib
import json
import mimetypes
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import tempfile
import uuid

import workspace

BASE_KEYS = {'format', 'schema', 'server', 'ui'}
V2_KEYS = BASE_KEYS | {'sources', 'generated', 'public', 'dependencies', 'database', 'run', 'tests'}
PUBLIC_EXTENSIONS = {'.html', '.css', '.js', '.png', '.jpg', '.jpeg', '.webp', '.gif',
                     '.svg', '.ico', '.woff', '.woff2', '.ttf', '.wasm', '.webmanifest'}
GENERATED = ('ProtocolTypes.idr', 'Protocol.idr', 'Client.idr')


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError('Duplicate configuration key: ' + key)
        result[key] = value
    return result


def local_path(project, value, label, exists=False):
    if not isinstance(value, str) or not value or '\\' in value or '\x00' in value:
        raise ValueError(label + ' must be a nonempty relative POSIX path')
    path = PurePosixPath(value)
    if path.is_absolute() or '..' in path.parts:
        raise ValueError(label + ' must stay inside the application')
    resolved = (project / value).resolve()
    if not resolved.is_relative_to(project.resolve()):
        raise ValueError(label + ' resolves outside the application')
    if exists and not resolved.exists():
        raise ValueError('Missing ' + label + ': ' + value)
    return resolved


def load(project):
    project = Path(project).resolve()
    cfg = json.loads((project / 'flux.json').read_text(), object_pairs_hook=unique_object)
    if not isinstance(cfg, dict) or type(cfg.get('format')) is not int or cfg['format'] not in [1, 2]:
        raise ValueError('Unsupported flux.json format (expected 1 or 2)')
    if not BASE_KEYS <= cfg.keys() or cfg.keys() - (BASE_KEYS if cfg['format'] == 1 else V2_KEYS):
        raise ValueError('Unsupported flux.json fields')
    for key in ['schema', 'server', 'ui']:
        path = local_path(project, cfg[key], key, exists=True)
        if not path.is_file():
            raise ValueError(key + ' must name a file')
    if cfg['server'] == cfg['ui']:
        raise ValueError('Server and UI manifests must be distinct')
    if cfg.get('dependencies', 'workspace') not in ['workspace', 'managed']:
        raise ValueError('dependencies must be workspace or managed')
    if cfg.get('database', 'postgres') not in ['postgres', 'none']:
        raise ValueError('database must be postgres or none')
    sources = cfg.get('sources', ['.'])
    if not isinstance(sources, list) or not sources:
        raise ValueError('sources must be a nonempty list of directories')
    source_roots = []
    for source in sources:
        directory = local_path(project, source, 'source directory', True)
        if not directory.is_dir():
            raise ValueError('sources must name directories')
        source_roots.append(directory)
    from devwatch import property_value
    for key in ['server', 'ui']:
        manifest = project / cfg[key]
        text = manifest.read_text()
        source = manifest.parent / (property_value(text, 'sourcedir') or '.')
        actual = local_path(project, str(source.relative_to(project)), key + ' sourcedir', True)
        if not any(actual.is_relative_to(root) for root in source_roots):
            raise ValueError(key + ' sourcedir is not covered by sources')
        if property_value(text, 'builddir') not in ['', 'build'] or property_value(text, 'outputdir') not in ['', 'build/exec']:
            raise ValueError('Custom ipkg builddir/outputdir is not supported by the Flux artifact layout')
    generated = cfg.get('generated', {'directory': '.', 'namespace': '', 'openapi': 'openapi.json'})
    if not isinstance(generated, dict) or set(generated) != {'directory', 'namespace', 'openapi'}:
        raise ValueError('generated requires directory, namespace and openapi')
    out = local_path(project, generated['directory'], 'generated directory')
    openapi = local_path(project, generated['openapi'], 'OpenAPI output')
    namespace = generated['namespace']
    if not isinstance(namespace, str) or (namespace and not re.fullmatch(r'[A-Z][A-Za-z0-9_]*(?:\.[A-Z][A-Za-z0-9_]*)*', namespace)):
        raise ValueError('Invalid generated module namespace')
    protected = {project / cfg[key] for key in ['schema', 'server', 'ui']} | {project / 'flux.json', project / 'pack.toml'}
    if openapi in protected or any(out / name in protected for name in GENERATED):
        raise ValueError('Generated output would overwrite application configuration/input')
    public = cfg.get('public', {'directory': '.', 'files': ['index.html', 'app.css']})
    if not isinstance(public, dict) or set(public) != {'directory', 'files'}:
        raise ValueError('public requires directory and files')
    local_path(project, public['directory'], 'public directory', True)
    if not isinstance(public['files'], list) or not public['files'] or not all(isinstance(p, str) for p in public['files']):
        raise ValueError('public.files must be a nonempty list of relative glob patterns')
    for pattern in public['files']:
        if not re.fullmatch(r'[A-Za-z0-9_./*?-]+', pattern) or '..' in PurePosixPath(pattern).parts or pattern.startswith('/'):
            raise ValueError('Unsafe public file pattern: ' + pattern)
    tests = cfg.get('tests', [])
    if not isinstance(tests, list) or any(not isinstance(cmd, list) or not cmd or
            not all(isinstance(arg, str) and arg and '\x00' not in arg for arg in cmd) for cmd in tests):
        raise ValueError('tests must be a list of nonempty argument arrays (no shell expansion)')
    run = cfg.get('run', {'web': False})
    if not isinstance(run, dict) or set(run) != {'web'} or type(run['web']) is not bool:
        raise ValueError('run requires web: true/false')
    return cfg


def generated_config(cfg):
    return cfg.get('generated', {'directory': '.', 'namespace': '', 'openapi': 'openapi.json'})


def generated_files(project, cfg):
    out = generated_config(cfg)
    return tuple([project / out['directory'] / name for name in GENERATED] + [project / out['openapi']])


def public_files(project, cfg):
    public = cfg.get('public', {'directory': '.', 'files': ['index.html', 'app.css']})
    root = local_path(project, public['directory'], 'public directory', True)
    files = {}
    for pattern in public['files']:
        matches = list(root.glob(pattern))
        if not matches:
            raise ValueError('Public pattern has no files: ' + pattern)
        for path in matches:
            relative = path.relative_to(root)
            if path.is_dir():
                continue
            if path.is_symlink() or any((root / Path(*relative.parts[:i])).is_symlink() for i in range(1, len(relative.parts))):
                raise ValueError('Public symlinks are not allowed: ' + str(relative))
            if not path.resolve().is_relative_to(root) or not re.fullmatch(r'[A-Za-z0-9_./-]+', relative.as_posix()):
                raise ValueError('Unsafe public asset: ' + str(relative))
            if any(part.startswith('.') for part in relative.parts) or path.suffix.lower() not in PUBLIC_EXTENSIONS:
                raise ValueError('Not a public web asset: ' + str(relative))
            if relative.as_posix() == 'app.js' or relative.parts[0] == 'build':
                raise ValueError('app.js and build/ are reserved for compiled output')
            files[relative.as_posix()] = path
    if not {'index.html', 'app.css'} <= files.keys():
        raise ValueError('public.files must include index.html and app.css')
    if len(files) > 4095:
        raise ValueError('Too many public assets (maximum 4095 plus compiled UI)')
    return files


def package_name(path):
    match = re.search(r'^\s*package\s+([a-zA-Z0-9_-]+)\s*$', path.read_text(), re.M)
    if not match:
        raise ValueError('Expected package declaration in ' + str(path))
    return match[1]


def package_graph(project, cfg, framework):
    manifest = workspace.load()
    known = {name: framework / path for name, path in manifest['packages'].items()}
    roots = {key: package_name(project / cfg[key]) for key in ['ui', 'server']}
    if roots['ui'] == roots['server']:
        raise ValueError('Application package names must be distinct')
    paths = {roots[key]: project / cfg[key] for key in roots}
    graph, queue = {}, list(paths)
    while queue:
        name = queue.pop()
        if name in graph:
            continue
        path = paths[name]
        if name in known and known[name].resolve() != path.resolve():
            raise ValueError('Application package collides with framework package: ' + name)
        graph[name] = workspace.dependencies(path.read_text())
        for dep in graph[name]:
            if dep in known and dep not in paths:
                paths[dep] = known[dep]
                queue.append(dep)
    visited, queue = set(), [roots['ui']]
    while queue:
        name = queue.pop()
        if name in visited:
            continue
        visited.add(name)
        queue.extend(graph.get(name, []))
    if visited.intersection(manifest['browser_forbidden']):
        raise ValueError('Application browser depends on a server-only package')
    return paths, manifest


def managed(project, cfg, framework):
    return cfg.get('dependencies', 'workspace' if project.is_relative_to(framework) else 'managed') == 'managed'


def pack_config(project, cfg, framework):
    paths, manifest = package_graph(project, cfg, framework)
    lines = ['# Generated by flux sync. Local dependencies come from the selected Flux checkout.',
             'collection = ' + json.dumps(manifest['collection']), '']
    for name, path in sorted(paths.items()):
        lines += [f'[custom.all.{name}]', 'type = "local"',
                  'path = ' + json.dumps(os.path.relpath(path.parent, project)),
                  'ipkg = ' + json.dumps(path.name), '']
    # Pinned external (git) dependencies, same as tools/workspace.py's own
    # pack_config: unconditionally included, not filtered by whether this
    # application's locally-readable ipkg files directly name them. A git
    # package can only resolve its own transitive deps (e.g. iris-client ->
    # iris) against other globally-known collection/git packages in the same
    # pack.toml, not by this script introspecting a remote ipkg it has no
    # local copy of - so there's no reliable way to compute a smaller exact
    # subset here. Previously omitted entirely, which broke every managed
    # external application whose server or UI transitively needed one of
    # these (e.g. flux.ipkg -> runtime, any Iris UI -> iris/iris-client).
    for name, dep in sorted(manifest.get('external_packages', {}).items()):
        lines += [f'[custom.all.{name}]', 'type = "git"',
                  'url = ' + json.dumps(dep['url']), 'commit = ' + json.dumps(dep['commit']),
                  'ipkg = ' + json.dumps(dep['ipkg'])]
        if 'test' in dep:
            lines += ['test = ' + json.dumps(dep['test'])]
        lines += ['']
    return '\n'.join(lines).rstrip() + '\n'


def check_dependencies(project, cfg, framework):
    package_graph(project, cfg, framework)
    if managed(project, cfg, framework):
        path = project / 'pack.toml'
        if not path.is_file() or path.read_text() != pack_config(project, cfg, framework):
            raise ValueError('Application dependency map is stale/missing; run flux sync and review pack.toml')


def build_cwd(project, cfg, framework):
    return project if managed(project, cfg, framework) else framework


def executable(project, manifest):
    text = (project / manifest).read_text()
    match = re.search(r'^executable\s*=\s*"?([a-zA-Z0-9_-]+)"?\s*$', text, re.M)
    if not match:
        raise ValueError('Expected a simple executable name in ' + manifest)
    return match[1]


def output(project, cfg, target):
    return (project / cfg[target]).parent / 'build/exec'


def asset_paths(project, cfg):
    names = cfg.get('_publicFiles', ['index.html', 'app.css'])
    paths = {'/' + name: (project / name, mime(name)) for name in names}
    paths['/'] = paths['/index.html']
    paths['/app.js'] = (project / 'build/exec' / executable(project, cfg['ui']), 'text/javascript; charset=utf-8')
    return paths


def mime(name):
    return {'.js': 'text/javascript', '.css': 'text/css', '.html': 'text/html',
            '.svg': 'image/svg+xml'}.get(Path(name).suffix, mimetypes.guess_type(name)[0] or 'application/octet-stream')


def copy_artifacts(project, cfg, destination):
    files = public_files(project, cfg)
    server = executable(project, cfg['server'])
    ui = executable(project, cfg['ui'])
    native = output(project, cfg, 'server') / (server + '_app')
    if not (native / (server + '.so')).is_file() or not (output(project, cfg, 'ui') / ui).is_file():
        raise ValueError('Application not built; run flux build first')
    for name, source in files.items():
        target = destination / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, target)
    (destination / 'build/exec').mkdir(parents=True, exist_ok=True)
    shutil.copytree(native, destination / 'build/exec' / (server + '_app'), dirs_exist_ok=True)
    shutil.copyfile(output(project, cfg, 'ui') / ui, destination / 'build/exec' / ui)
    for key in ['server', 'ui']:
        (destination / (key + '.ipkg')).write_text('executable = ' + executable(project, cfg[key]) + '\n')
    return {'server': 'server.ipkg', 'ui': 'ui.ipkg', '_publicFiles': sorted(files)}


def workdir(project):
    root = project / '.workspace'
    root.mkdir(exist_ok=True)
    if root.is_symlink() or not root.resolve().is_relative_to(project.resolve()):
        raise ValueError('Unsafe application .workspace directory')
    return root


def stage(project, cfg):
    # Immutable revisions avoid races with a running dev backend's cwd. Old
    # stages are removed by the owning CLI after dev exits, not during a swap.
    directory = Path(tempfile.mkdtemp(prefix='stage-', dir=workdir(project)))
    try:
        return directory, copy_artifacts(project, cfg, directory)
    except BaseException:
        shutil.rmtree(directory)
        raise


def release(project, cfg, atomic_write):
    releases = workdir(project) / 'releases'
    releases.mkdir(exist_ok=True)
    if releases.is_symlink():
        raise ValueError('Unsafe releases directory')
    identifier = uuid.uuid4().hex
    directory = releases / identifier
    directory.mkdir()
    try:
        staged = copy_artifacts(project, cfg, directory)
        public = directory / '.public'
        public.mkdir()
        for name in staged['_publicFiles']:
            target = public / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.move(str(directory / name), target)
        shutil.copyfile(directory / 'build/exec' / executable(project, cfg['ui']), public / 'app.js')
        (public / '.flux-assets').write_text('\n'.join(staged['_publicFiles'] + ['app.js']) + '\n')
        hashes = {str(p.relative_to(directory)): hashlib.sha256(p.read_bytes()).hexdigest()
                  for p in directory.rglob('*') if p.is_file()}
        metadata = {'format': 1, 'release': 'releases/' + identifier, 'config': cfg,
                    'server': staged['server'], 'ui': staged['ui'], 'hashes': hashes}
        atomic_write(workdir(project) / 'application.json', (json.dumps(metadata, indent=2) + '\n').encode())
    except BaseException:
        shutil.rmtree(directory)
        raise
    return directory


def built_release(project, cfg):
    manifest = workdir(project) / 'application.json'
    if not manifest.is_file():
        raise ValueError('No built application artifact; run flux build first')
    data = json.loads(manifest.read_text(), object_pairs_hook=unique_object)
    if (not isinstance(data, dict) or set(data) != {'format', 'release', 'config', 'server', 'ui', 'hashes'}
            or type(data['format']) is not int or data['format'] != 1
            or not isinstance(data['release'], str) or not re.fullmatch(r'releases/[0-9a-f]{32}', data['release'])
            or not isinstance(data['hashes'], dict)
            or not {'server.ipkg', 'ui.ipkg', '.public/.flux-assets', '.public/index.html', '.public/app.js', '.public/app.css'} <= data['hashes'].keys()
            or any(not isinstance(digest, str) or not re.fullmatch(r'[0-9a-f]{64}', digest) for digest in data['hashes'].values())):
        raise ValueError('Invalid application build manifest')
    if data.get('config') != cfg:
        raise ValueError('Application configuration changed; run flux build again')
    directory = local_path(workdir(project), data['release'], 'release', True)
    if set(data['hashes']) != {str(path.relative_to(directory)) for path in directory.rglob('*') if path.is_file()}:
        raise ValueError('Built artifact file list changed; run flux build again')
    for name, digest in data['hashes'].items():
        path = local_path(directory, name, 'artifact file', True)
        if hashlib.sha256(path.read_bytes()).hexdigest() != digest:
            raise ValueError('Built artifact changed; run flux build again: ' + name)
    if data.get('server') != 'server.ipkg' or data.get('ui') != 'ui.ipkg':
        raise ValueError('Invalid built package manifests')
    return directory, {'server': 'server.ipkg', 'ui': 'ui.ipkg'}
