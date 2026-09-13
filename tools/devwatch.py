"""Flux development live reload and opt-in DOM HMR. Standard library, loopback only.

Applications supply watch/build/stage hooks. Published assets and native runtimes
are snapshots, never the compiler's mutable output directory. The database is
owned by the caller for the entire session, not by a build or backend generation.
"""
from dataclasses import dataclass
import concurrent.futures
import hashlib
import os
from pathlib import Path
import re
import shutil
import socket
import subprocess
import tempfile
import threading
import time
import uuid

import workspace

IGNORED = {'build', '.workspace', '.git', 'node_modules', '__pycache__', 'tests', 'test', 'docs', 'design'}
EXTENSIONS = {'.idr', '.ipkg', '.c', '.h', '.ss', '.scm', '.py', '.json', '.toml',
              '.css', '.html', '.js', '.png', '.jpg', '.jpeg', '.svg', '.webp', '.woff', '.woff2'}


@dataclass(frozen=True)
class WatchPath:
    path: Path
    kind: str  # ui, server, both, schema, css, reload, assets


@dataclass
class DevHooks:
    sources: object  # () -> iterable[WatchPath]; recalculated to discover new dependencies
    build: object    # (set[kind], BuildRunner) -> None
    stage: object    # () -> (asset/build directory, config)
    exclude: object = ()  # iterable or callable returning generated files/directories
    ready: object = None  # optional (port, process) -> bool, in addition to TCP readiness
    hot: bool = False  # opt-in DOM HMR; requires runWebHot in the application


def property_value(text, name):
    text = re.sub(r'--[^\n]*', '', text)
    match = re.search(r'^\s*' + name + r'\s*=(.*?)(?=^\s*[\w-]+\s*=(?!=)|\Z)', text, re.M | re.S)
    return match[1].strip().strip('"') if match else ''


def package_sources(project, config, packages):
    """Classify application modules and transitive local package roots by target.

    packages maps dependency names to absolute ipkg files. Unlisted (installed)
    dependencies are not watched. Unknown new application Idris files trigger both
    targets; explicitly listed modules have the more precise classification.
    """
    project = Path(project).resolve()
    result = [WatchPath(project / directory, 'both') for directory in config.get('sources', ['.'])]
    local = {}
    for target in ['ui', 'server']:
        manifest = project / config[target]
        text = manifest.read_text()
        result.append(WatchPath(manifest, 'both'))
        source = manifest.parent / (property_value(text, 'sourcedir') or '.')
        modules = property_value(text, 'modules').split(',')
        modules += [property_value(text, 'main')]
        for module in modules:
            if re.fullmatch(r'[A-Za-z0-9_.]+', module.strip()):
                file = (source / (module.strip().replace('.', '/') + '.idr')).resolve()
                local.setdefault(file, set()).add(target)
        seen, queue = set(), list(workspace.dependencies(text))
        while queue:
            name = queue.pop()
            if name in seen or name not in packages:
                continue
            seen.add(name)
            path = Path(packages[name]).resolve()
            local.setdefault(path.parent, set()).add(target)
            queue.extend(workspace.dependencies(path.read_text()))
    result += [WatchPath(path, 'both' if len(kinds) > 1 else next(iter(kinds)))
               for path, kinds in local.items()]
    result += [WatchPath(project / config['schema'], 'schema'),
               WatchPath(project / 'index.html', 'reload'), WatchPath(project / 'app.css', 'css')]
    return result


def refresh_native(paths):
    """pack does not track native C freshness. Refresh local prebuild manifests.

    The watcher fingerprints manifest contents, so these timestamp-only touches
    cannot create a rebuild loop. Runtime snapshots keep old libraries intact.
    """
    manifests = set()
    for item in paths:
        path = Path(item.path)
        if path.is_dir():
            manifests.update(path.glob('*.ipkg'))
        elif path.suffix == '.ipkg':
            manifests.add(path)
    for path in manifests:
        if property_value(path.read_text(), 'prebuild'):
            path.touch()


def snapshot(paths, exclude=()):
    """Stat polling handles creates/deletes/atomic editor saves without dependencies.

    Most-specific watch path wins; ties union their target kinds. Symlinked
    directories/files are not traversed. Explicit generated outputs are excluded.
    """
    excluded = [Path(p).resolve() for p in exclude]
    records, specificity = {}, {}
    for item in paths:
        root = Path(item.path)
        if root.is_symlink():
            continue
        root = root.resolve()
        candidates = []
        if root.is_dir():
            for directory, dirs, files in os.walk(root, followlinks=False):
                dirs[:] = [d for d in dirs if d not in IGNORED and not d.startswith('.')
                           and not (Path(directory) / d).is_symlink()]
                candidates.extend(Path(directory) / f for f in files
                                  if not f.startswith('.') and (Path(f).suffix in EXTENSIONS or f == 'Makefile'))
        else:
            candidates = [root]
        for path in candidates:
            if path.is_symlink() or any(path == e or e in path.parents for e in excluded):
                continue
            try:
                stat = path.stat()
            except FileNotFoundError:
                continue
            kind = item.kind
            if kind == 'assets':
                kind = 'css' if path.suffix == '.css' else 'reload'
            kinds = {kind}
            if path.suffix in {'.c', '.h', '.ss', '.scm'} or path.name == 'Makefile':
                kinds.add('native')
            fingerprint = hashlib.sha256(path.read_bytes()).hexdigest() if path.suffix == '.ipkg' else stat.st_mtime_ns
            depth = len(root.parts)
            previous = specificity.get(path, -1)
            if depth > previous:
                specificity[path] = depth
                records[path] = (fingerprint, stat.st_size, frozenset(kinds))
            elif depth == previous:
                records[path] = (fingerprint, stat.st_size, records[path][2] | kinds)
    return records


def changes(before, after):
    kinds = set()
    for path in before.keys() | after.keys():
        if before.get(path) != after.get(path):
            for value in [before.get(path), after.get(path)]:
                if value:
                    kinds.update(value[2])
    return kinds


class BuildRunner:
    """One serialized, cancellable process group. Bounded compiler diagnostics."""
    def __init__(self, env):
        self.cancelled = threading.Event()
        self.env = env
        self.diagnostics = ''

    def redact(self, value):
        for key, secret in self.env.items():
            if any(word in key.upper() for word in ['PASSWORD', 'SECRET', 'TOKEN', 'CREDENTIAL']) and secret:
                value = value.replace(secret, '[redacted]')
        return value[-24000:]

    def run(self, args, cwd=None, timeout=600):
        if self.cancelled.is_set():
            raise RuntimeError('Build cancelled')
        with tempfile.TemporaryFile() as output:
            process = subprocess.Popen(args, cwd=cwd, stdout=output, stderr=subprocess.STDOUT,
                                       start_new_session=True)
            started = time.monotonic()
            try:
                while process.poll() is None:
                    if self.cancelled.wait(.1):
                        raise RuntimeError('Build cancelled')
                    if time.monotonic() - started > timeout:
                        raise RuntimeError('Build timed out')
                output.seek(0, 2)
                output.seek(max(0, output.tell() - 24000))
                diagnostic = self.redact(output.read().decode(errors='replace'))
                self.diagnostics = (self.diagnostics + diagnostic)[-24000:]
                if diagnostic:
                    print(diagnostic, end='', flush=True)
                if process.returncode:
                    raise RuntimeError('Compilation failed.\n' + self.diagnostics)
            finally:
                # Also reap descendants of a compiler which has already exited.
                workspace.stop_group(process)


class Published:
    def __init__(self, hot=False):
        self.lock = threading.Lock()
        self.assets = {}
        self.port = None
        self.session = uuid.uuid4().hex
        self.css = 0
        self.ui = 0
        self.hot = hot
        self.reload = 0
        self.building = False
        self.error = ''

    def status(self):
        with self.lock:
            return dict(session=self.session, css=self.css, ui=self.ui, hot=self.hot, reload=self.reload,
                        building=self.building, error=self.error)

    def backend(self):
        with self.lock:
            return self.port

    def asset(self, path, ui_revision=None, reload_revision=None, session=None):
        with self.lock:
            if ui_revision is not None and (ui_revision != str(self.ui) or
                    reload_revision != str(self.reload) or session != self.session):
                return None  # stale hot requests must not receive a newer bundle
            value = self.assets.get(path)
            if value and path in ['/', '/index.html']:
                data, mime = value
                script = ('<script src="/__flux_dev/hot.js"></script>' if self.hot else '')
                script += ('<link rel="stylesheet" href="/__flux_dev/client.css">'
                          '<script defer src="/__flux_dev/client.js?s=' + self.session +
                          '&amp;r=' + str(self.reload) + '&amp;c=' + str(self.css) + '&amp;u=' + str(self.ui) + '"></script>')
                # Only served HTML is instrumented; source and production builds are untouched.
                data = re.sub(br'</head\s*>', lambda match: script.encode() + match[0], data, count=1, flags=re.I)
                return data, mime
            if value and path == '/app.js' and self.hot:
                # Separate lexical scope per complete Idris bundle. No eval,
                # unsafe-inline or raw generated constructor transfer.
                return b'(() => {\n' + value[0] + b'\n})();\n', value[1]
            return value

    def publish(self, assets, port, kinds):
        with self.lock:
            self.assets, self.port = assets, port
            if kinds:
                if self.hot and kinds <= {'ui', 'css'}:
                    if 'ui' in kinds:
                        self.ui += 1
                    if 'css' in kinds:
                        self.css += 1
                elif kinds <= {'css'}:
                    self.css += 1
                else:
                    self.reload += 1
            self.building = False
            self.error = ''

    def report(self, building=False, error=''):
        with self.lock:
            self.building, self.error = building, error


def asset_snapshot(project, config):
    import application
    html = (project / 'index.html').read_bytes()
    if not re.search(br'</head\s*>', html, re.I):
        raise ValueError('Watch HTML needs an explicit closing </head> for the development client')
    return {url: (path.read_bytes(), mime) for url, (path, mime) in application.asset_paths(project, config).items()}


class Backend:
    def __init__(self, directory, process, port):
        self.directory, self.process, self.port = directory, process, port

    @classmethod
    def start(cls, project, config, env, runner, ready=None):
        import flux
        name = flux.executable(project, config['server'])
        directory = tempfile.TemporaryDirectory(prefix='flux-dev-backend-')
        process = None
        try:
            # Chez's .so and every adjacent native library must outlive the build
            # which created them. A new build must not mutate a running runtime.
            app = Path(directory.name) / 'build/exec' / (name + '_app')
            shutil.copytree(project / 'build/exec' / (name + '_app'), app)
            manifest = Path(directory.name) / 'server.ipkg'
            manifest.write_text('executable = ' + name + '\n')
            binary, runtime_env = flux.server_command(Path(directory.name), {'server': 'server.ipkg'}, env)
            with socket.socket() as sock:
                sock.bind(('127.0.0.1', 0))
                port = sock.getsockname()[1]
            process = subprocess.Popen([binary, str(port), '128'], cwd=project, env=runtime_env,
                                       start_new_session=True)
            backend = cls(directory, process, port)
            deadline = time.monotonic() + 30
            while time.monotonic() < deadline:
                if runner.cancelled.wait(.1):
                    raise RuntimeError('Backend startup cancelled')
                if process.poll() is not None:
                    raise RuntimeError('Candidate API exited during startup; previous API retained')
                try:
                    with socket.create_connection(('127.0.0.1', port), timeout=.1):
                        if ready is None or ready(port, process):
                            return backend
                except OSError:
                    pass
            raise RuntimeError('Candidate API readiness timed out; previous API retained')
        except BaseException:
            if process is not None:
                workspace.stop_group(process)
            directory.cleanup()
            raise

    def stop(self):
        try:
            if self.process.poll() is None:
                self.process.terminate()
                try:
                    self.process.wait(timeout=40)
                except subprocess.TimeoutExpired:
                    print('Flux API shutdown deadline exceeded; forcing process-group cleanup', flush=True)
        finally:
            # A Ctrl-C during retirement must still reap this old generation,
            # not just the current backend owned by watch_dev's outer finally.
            try:
                workspace.stop_group(self.process)
            finally:
                self.directory.cleanup()


def watch_dev(project, config, env, port, hooks, debounce=.3):
    import http.server
    import flux
    published = Published(hot=hooks.hot)
    runner = BuildRunner(env)
    executor = concurrent.futures.ThreadPoolExecutor(max_workers=1, thread_name_prefix='flux-build')
    future = None
    backend = None
    web = None
    serving = None
    # Capture before staging so generated writes cannot feed the watcher.
    def excluded():
        return hooks.exclude() if callable(hooks.exclude) else hooks.exclude
    before = snapshot(hooks.sources(), excluded())
    pending = set()
    failed = set()
    deadline = 0
    scan_error = ''
    try:
        assets = asset_snapshot(project, config)
        backend = Backend.start(project, config, env, runner, hooks.ready)
        published.publish(assets, backend.port, set())
        web = http.server.ThreadingHTTPServer(('127.0.0.1', port),
                                              flux.handler(project, config, backend.port, live=published))
        serving = threading.Thread(target=web.serve_forever, name='flux-dev-http')
        serving.start()
        print(f'Flux development URL: http://127.0.0.1:{web.server_port} (watch enabled)', flush=True)

        def rebuild(kinds):
            runner.diagnostics = ''
            hooks.build(kinds, runner)
            staged, cfg = hooks.stage()
            assets = asset_snapshot(staged, cfg)
            candidate = None
            if kinds & {'server', 'both', 'schema'}:
                candidate = Backend.start(staged, cfg, env, runner, hooks.ready)
            return assets, candidate

        while True:
            try:
                after = snapshot(hooks.sources(), excluded())
                delta = changes(before, after)
                if scan_error:
                    delta |= {'both'}
                    scan_error = ''
                if delta:
                    pending |= delta
                    deadline = time.monotonic() + debounce
                    before = after
            except (OSError, ValueError, KeyError) as error:
                # Invalid/deleted manifests must not kill the last good process.
                message = runner.redact(str(error))
                if message != scan_error:
                    published.report(error=message)
                    scan_error = message

            if future is not None and future.done():
                try:
                    assets, candidate = future.result()
                    # Do not expose a superseded build, especially a mixed UI/API
                    # generation. Rebuild the union after the latest save settles.
                    if pending or scan_error:
                        if candidate:
                            candidate.stop()
                        pending |= active
                    else:
                        previous = backend
                        if candidate:
                            backend = candidate
                        published.publish(assets, backend.port, active)
                        failed.clear()
                        print('Flux live reload: published ' + ', '.join(sorted(active)), flush=True)
                        if candidate:
                            previous.stop()  # admitted writes drain; never replay requests
                except Exception as error:
                    failed |= active
                    published.report(error=runner.redact(str(error)))
                    print('Flux live reload: build failed; last successful application retained', flush=True)
                finally:
                    future = None
            if future is None and pending and not scan_error and time.monotonic() >= deadline:
                active, pending = pending | failed, set()
                published.report(building=True)
                future = executor.submit(rebuild, active)
            if backend.process.poll() is not None:
                published.report(error='API exited unexpectedly. Save a server source file to rebuild. No requests will be replayed.')
            time.sleep(.1)
    finally:
        runner.cancelled.set()
        try:
            if future is not None:
                try:
                    _, candidate = future.result(timeout=50)
                    if candidate:
                        candidate.stop()
                except Exception:
                    pass
            executor.shutdown(wait=True, cancel_futures=True)
        finally:
            if web:
                web.shutdown()
                web.server_close()
            if serving:
                serving.join()
            if backend:
                backend.stop()
