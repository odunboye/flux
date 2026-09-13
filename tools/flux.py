#!/usr/bin/env python3
"""Flux workspace/external application CLI (preview, standard-library only)."""
import argparse
import contextlib
import http.client
import http.server
import json
import os
from pathlib import Path
import re
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
import uuid
from urllib.parse import parse_qs

import workspace
import application

ROOT = Path(__file__).resolve().parents[1]
TEMPLATE_FILES = ['Main.idr', 'TodoUI.idr', 'MainWeb.idr', 'server.ipkg', 'ui.ipkg',
                  'schema.json', 'flux.json', 'index.html', 'app.css', 'OWNERSHIP_MIGRATION.md']


def run(args, **kwargs):
    timeout = kwargs.pop('timeout', 600)
    with subprocess.Popen(args, start_new_session=True, **kwargs) as process:
        try:
            output, errors = process.communicate(timeout=timeout)
        except BaseException:
            workspace.stop_group(process)
            raise
        if process.returncode:
            workspace.stop_group(process)
            raise subprocess.CalledProcessError(process.returncode, args, output, errors)
        return subprocess.CompletedProcess(args, process.returncode, output, errors)


def project_config(path=None):
    if path is not None:
        project = Path(path).expanduser().resolve()
        if project.name == 'flux.json' and project.is_file():
            project = project.parent
    else:
        cwd = Path.cwd().resolve()
        project = next((p for p in [cwd, *cwd.parents] if (p / 'flux.json').is_file()), None)
        if project is None and cwd == ROOT.resolve():
            project = ROOT / 'platform/crud'  # backwards-compatible workspace default
        if project is None:
            raise ValueError('No flux.json found; enter an application or use --project <path>')
    return project, application.load(project)


def generate(project, config, check=False, execute=None):
    execute = execute or run
    output = application.generated_config(config)
    command = [sys.executable, str(ROOT / 'platform/generate.py'), str(project / config['schema']),
               '--out', str(project / output['directory'])]
    if output['namespace']:
        command += ['--namespace', output['namespace']]
    if output['openapi'] != str(Path(output['directory']) / 'openapi.json'):
        command += ['--openapi', str(project / output['openapi'])]
    execute(command + (['--check'] if check else []), cwd=application.build_cwd(project, config, ROOT))


def build(project, config):
    application.check_dependencies(project, config, ROOT)
    generate(project, config, check=True)
    cwd = application.build_cwd(project, config, ROOT)
    run(['pack', '--no-prompt', 'build', str(project / config['server'])], cwd=cwd)
    run(['pack', '--no-prompt', 'install', 'flux-ui'], cwd=cwd)
    run(['pack', '--no-prompt', '--cg', 'javascript', 'build', str(project / config['ui'])], cwd=cwd)
    artifact = application.release(project, config, atomic_write)
    print('Built application artifact: ' + str(artifact), flush=True)


executable = application.executable


def atomic_write(path, data):
    with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as out:
        temp = Path(out.name)
        try:
            out.write(data)
            out.flush()
            os.replace(temp, path)
        finally:
            temp.unlink(missing_ok=True)


def new_project(name):
    if len(name) > 48 or not re.fullmatch(r'[a-z][a-z0-9]*(?:-[a-z0-9]+)*', name):
        raise ValueError('Use a lowercase application name (letters, digits, hyphens)')
    import fcntl
    (ROOT / '.workspace').mkdir(exist_ok=True)
    with (ROOT / '.workspace/cli.lock').open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        manifest_path, pack_path = ROOT / 'workspace.json', ROOT / 'pack.toml'
        original, original_pack = manifest_path.read_bytes(), pack_path.read_bytes()
        manifest = json.loads(original)
        workspace.check(manifest)
        target = ROOT / 'apps' / name
        target.parent.resolve().relative_to(ROOT)
        if target.exists() or target.is_symlink():
            raise ValueError('Application already exists; nothing overwritten')
        for suffix in ['server', 'ui']:
            if name + '-' + suffix in manifest['packages']:
                raise ValueError('Package name already registered')
        target.mkdir(parents=True)
        try:
            for file in TEMPLATE_FILES:
                shutil.copyfile(ROOT / 'platform/crud' / file, target / file)
            for suffix in ['server', 'ui']:
                file = target / (suffix + '.ipkg')
                file.write_text(file.read_text().replace('platform-crud-' + suffix, name + '-' + suffix))
                manifest['packages'][name + '-' + suffix] = f'apps/{name}/{suffix}.ipkg'
            manifest['browser_roots'].append(name + '-ui')
            generate(target, json.loads((target / 'flux.json').read_text()))
            if manifest_path.read_bytes() != original or pack_path.read_bytes() != original_pack:
                raise ValueError('Workspace changed concurrently; retry creation')
            atomic_write(manifest_path, (json.dumps(manifest, indent=2) + '\n').encode())
            atomic_write(pack_path, workspace.pack_config(manifest).encode())
            workspace.check(manifest)
        except BaseException:
            # Only remove the directory created by this operation. Restore map
            # files only if this operation reached the registration phase.
            if manifest_path.read_bytes() == (json.dumps(manifest, indent=2) + '\n').encode():
                atomic_write(manifest_path, original)
                atomic_write(pack_path, original_pack)
            shutil.rmtree(target)
            raise
    print(f'Created apps/{name}. Next: ./flux --project apps/{name} build')


@contextlib.contextmanager
def database(disposable):
    if not disposable:
        # No fallback to a silently created/default application database.
        for key in ['PGHOST', 'PGPORT', 'PGUSER', 'PGPASSWORD', 'PGDATABASE']:
            if not os.environ.get(key):
                raise ValueError(f'{key} is required (or explicitly use --disposable-db)')
        yield dict(os.environ)
        return
    name = 'flux-dev-' + uuid.uuid4().hex
    password = uuid.uuid4().hex
    def docker(*args):
        return run(['docker', *args], timeout=60, text=True, stdout=subprocess.PIPE,
                   stderr=subprocess.PIPE).stdout.strip()
    def diagnostic(error):
        detail = getattr(error, 'stderr', None) or getattr(error, 'stdout', None)
        if detail is None:
            detail = type(error).__name__ if isinstance(error, subprocess.SubprocessError) else str(error)
        if isinstance(detail, bytes):
            detail = detail.decode(errors='replace')
        return detail.strip().replace(password, '[redacted]')
    # If Docker is unavailable, no container creation was attempted and there is
    # nothing to remove. Do not mask that failure with a misleading cleanup error.
    try:
        docker('info', '--format', '{{.ServerVersion}}')
    except (OSError, subprocess.SubprocessError) as error:
        raise RuntimeError('Docker daemon unavailable before database startup: ' + diagnostic(error)) from error
    primary = None
    try:
        docker('run', '--rm', '-d', '--name', name, '-p', '127.0.0.1::5432',
               '-e', 'POSTGRES_USER=fluxdev', '-e', 'POSTGRES_PASSWORD=' + password,
               '-e', 'POSTGRES_DB=fluxdev', 'postgres:16')
        for _ in range(150):
            try:
                docker('exec', name, 'pg_isready', '-h', '127.0.0.1', '-U', 'fluxdev', '-d', 'fluxdev')
                break
            except subprocess.CalledProcessError:
                time.sleep(.2)
        else:
            raise RuntimeError('Disposable PostgreSQL did not become ready')
        port = docker('port', name, '5432/tcp').rsplit(':', 1)[1]
        print(f'Disposable development database {name}: removed on exit; no persistent data.', flush=True)
        yield dict(os.environ, PGHOST='127.0.0.1', PGPORT=port, PGUSER='fluxdev',
                   PGPASSWORD=password, PGDATABASE='fluxdev')
    except BaseException as error:
        primary = error
        raise
    finally:
        try:
            docker('rm', '-f', '-v', name)
        except (OSError, subprocess.SubprocessError) as error:
            original = (' Original startup/session failure: ' + diagnostic(primary)) if primary is not None else ''
            raise RuntimeError(
                f'Failed to remove disposable database container {name}; data may remain. '
                f'Retry: docker rm -f -v {name}. Docker: {diagnostic(error)}' + original
            ) from error


def server_command(project, config, env):
    name = executable(project, config['server'])
    app = application.output(project, config, 'server') / (name + '_app')
    binary = app / (name + '.so')
    if not binary.is_file():
        raise ValueError('Server not built; run flux build first')
    return str(binary), dict(env, IDRIS2_INC_SRC=str(app), LD_LIBRARY_PATH=str(app),
                             DYLD_LIBRARY_PATH=str(app))


def handler(project, config, backend, live=None):
    assets = application.asset_paths(project, config)
    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, format, *args):
            if live is not None and getattr(self, 'path', '').partition('?')[0] == '/__flux_dev/status':
                return
            super().log_message(format, *args)

        def setup(self):
            super().setup()
            self.connection.settimeout(15)

        def reply(self, status, data, content_type):
            self.send_response(status)
            self.send_header('Content-Type', content_type)
            self.send_header('Content-Length', str(len(data)))
            self.send_header('Cache-Control', 'no-store')
            self.send_header('X-Content-Type-Options', 'nosniff')
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self):
            if live is not None:
                # Diagnostics are local source information. Protect GET too,
                # including against DNS rebinding; never emit permissive CORS.
                expected = 'http://127.0.0.1:' + str(self.server.server_port)
                if self.headers.get('Host') != expected.removeprefix('http://') or self.headers.get('Origin') not in [None, expected]:
                    self.reply(403, b'Cross-origin development request denied', 'text/plain')
                    return
                path = self.path.partition('?')[0]
                if path == '/__flux_dev/status':
                    self.reply(200, json.dumps(live.status()).encode(), 'application/json')
                    return
                if path in ['/__flux_dev/client.js', '/__flux_dev/client.css'] or (live.hot and path == '/__flux_dev/hot.js'):
                    name = path.rsplit('/', 1)[1]
                    mime = 'text/javascript' if name.endswith('.js') else 'text/css'
                    self.reply(200, (Path(__file__).parent / 'dev' / name).read_bytes(), mime)
                    return
                query = parse_qs(self.path.partition('?')[2])
                if path == '/app.js' and 'flux_hmr' in query:
                    if any(len(query.get(key, [])) != 1 for key in ['flux_hmr', 'flux_reload', 'flux_session']):
                        self.reply(400, b'Invalid hot revision', 'text/plain')
                        return
                    value = live.asset(path, query['flux_hmr'][0], query['flux_reload'][0], query['flux_session'][0])
                else:
                    value = live.asset(path)
                if value is None:
                    self.reply(404, b'Not found', 'text/plain')
                else:
                    self.reply(200, value[0], value[1])
                return
            asset = assets.get(self.path.partition('?')[0])
            if asset is None:
                self.reply(404, b'Not found', 'text/plain')
                return
            self.reply(200, asset[0].read_bytes(), asset[1])

        def do_POST(self):
            if not self.path.startswith('/rpc/v1/') or '?' in self.path:
                self.reply(404, b'Not found', 'text/plain')
                return
            # This proxy is development-only, not a general HTTP forwarder.
            origin = self.headers.get('Origin')
            expected = 'http://127.0.0.1:' + str(self.server.server_port)
            if self.headers.get('Host') != expected.removeprefix('http://') or origin not in [None, expected]:
                self.reply(403, b'Cross-origin development request denied', 'text/plain')
                return
            try:
                length = int(self.headers.get('Content-Length', '-1'))
            except ValueError:
                length = -1
            if not 0 <= length <= 65536 or self.headers.get('Transfer-Encoding'):
                self.reply(413, b'Invalid body size', 'text/plain')
                return
            credentials = self.headers.get_all('Authorization', [])
            if len(credentials) > 1 or (credentials and not re.fullmatch(r'(?i:Bearer) [A-Za-z0-9_-]{43}', credentials[0])):
                self.reply(400, b'Invalid authorization header', 'text/plain')
                return
            forwarded = {'Content-Type': 'application/json'}
            if credentials:
                forwarded['Authorization'] = credentials[0]
            # Capture the generation once. A cutover cannot redirect/replay an
            # already admitted write onto another backend.
            target = live.backend() if live is not None else backend
            conn = http.client.HTTPConnection('127.0.0.1', target, timeout=12)
            try:
                data = self.rfile.read(length)
                if len(data) != length:
                    self.reply(400, b'Truncated body', 'text/plain')
                    return
                conn.request('POST', self.path, data, forwarded)
                response = conn.getresponse()
                body = response.read(65537)
                if len(body) > 65536:
                    raise ValueError('Oversized RPC response')
                self.reply(response.status, body, 'application/json')
            except (OSError, ValueError, http.client.HTTPException):
                self.reply(502, b'{"error":{"code":"upstream_unavailable","message":"Development server unavailable"}}', 'application/json')
            finally:
                conn.close()
    return Handler


@contextlib.contextmanager
def staging_session():
    stages = []
    def stage(project, cfg):
        directory, config = application.stage(project, cfg)
        stages.append(directory)
        return directory, config
    try:
        yield stage
    finally:
        for directory in stages:
            shutil.rmtree(directory)


def watch_hooks(project, config, hot=False, stage=None):
    """Configuration-driven policy for both workspace and external applications."""
    from devwatch import DevHooks, WatchPath, package_sources, refresh_native
    stage = stage or application.stage

    def current():
        return project_config(project)[1]

    def sources():
        cfg = current()
        packages = {name: ROOT / path for name, path in workspace.load()['packages'].items()}
        paths = package_sources(project, cfg, packages)
        public = cfg.get('public', {'directory': '.', 'files': ['index.html', 'app.css']})
        if public['directory'] != '.':
            paths.append(WatchPath(project / public['directory'], 'assets'))
        else:
            paths += [WatchPath(path, 'css' if path.suffix == '.css' else 'reload')
                      for path in application.public_files(project, cfg).values()]
        return paths + [WatchPath(project / 'flux.json', 'schema'),
                        WatchPath(project / 'pack.toml', 'both'),
                        WatchPath(ROOT / 'pack.toml', 'both'), WatchPath(ROOT / 'workspace.json', 'both'),
                        WatchPath(ROOT / 'platform/generate.py', 'schema')]

    def rebuild(kinds, runner):
        cfg = current()
        application.check_dependencies(project, cfg, ROOT)
        if 'native' in kinds:
            refresh_native(sources())
        if not kinds & {'ui', 'server', 'both', 'schema'}:
            return
        if 'schema' in kinds:
            generate(project, cfg, execute=runner.run)
        generate(project, cfg, check=True, execute=runner.run)
        cwd = application.build_cwd(project, cfg, ROOT)
        if kinds & {'server', 'both', 'schema'}:
            runner.run(['pack', '--no-prompt', 'build', str(project / cfg['server'])], cwd=cwd)
        if kinds & {'ui', 'both', 'schema'}:
            runner.run(['pack', '--no-prompt', 'install', 'flux-ui'], cwd=cwd)
            runner.run(['pack', '--no-prompt', '--cg', 'javascript', 'build', str(project / cfg['ui'])], cwd=cwd)

    return DevHooks(sources, rebuild, lambda: stage(project, current()), hot=hot,
                    exclude=lambda: application.generated_files(project, current()))


def dev(project, config, env, port, watch=None):
    if watch is not None:
        from devwatch import watch_dev
        return watch_dev(project, config, env, port, watch)
    binary, env = server_command(project, config, env)
    for asset in ['index.html', 'app.css', 'build/exec/' + executable(project, config['ui'])]:
        if not (project / asset).is_file():
            raise ValueError('Missing UI asset; run flux.py build first')
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        backend = sock.getsockname()[1]
        web = http.server.ThreadingHTTPServer(('127.0.0.1', port), handler(project, config, backend))
    process = None
    try:
        process = subprocess.Popen([binary, str(backend), '128'], cwd=project, env=env,
                                   start_new_session=True)
        for _ in range(300):
            if process.poll() is not None:
                raise RuntimeError('API server exited during startup')
            try:
                with socket.create_connection(('127.0.0.1', backend), timeout=.1):
                    break
            except OSError:
                time.sleep(.1)
        else:
            raise RuntimeError('API server readiness timed out')
        print(f'Flux development URL: http://127.0.0.1:{web.server_port}', flush=True)
        web.timeout = .5
        while process.poll() is None:
            web.handle_request()
        raise RuntimeError('API server exited unexpectedly')
    finally:
        web.server_close()
        if process is not None:
            running = process.poll() is None
            if running:
                process.terminate()
            try:
                code = process.wait(timeout=40)
                if running and code != 0:
                    raise RuntimeError('API did not shut down cleanly')
            except subprocess.TimeoutExpired:
                workspace.stop_group(process)
                raise RuntimeError('API shutdown exceeded deadline')


def run_application(project, config, env, port):
    if not config.get('run', {}).get('web', False):
        raise ValueError('flux run requires format 2 run.web=true and Flux.Server.Assets integration; use dev for legacy API-only apps')
    directory, built_config = application.built_release(project, config)
    binary, runtime_env = server_command(directory, built_config, dict(env, FLUX_PUBLIC_DIR=str(directory / '.public')))
    if port == 0:
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0))
            port = sock.getsockname()[1]
    process = subprocess.Popen([binary, str(port), '128'], cwd=directory, env=runtime_env, start_new_session=True)
    try:
        for _ in range(300):
            if process.poll() is not None:
                raise RuntimeError('Native application exited during startup')
            conn = http.client.HTTPConnection('127.0.0.1', port, timeout=.2)
            try:
                conn.request('GET', '/')
                response = conn.getresponse()
                if response.status == 200 and response.getheader('X-Flux-Assets') == '1':
                    break
            except (OSError, http.client.HTTPException):
                pass
            finally:
                conn.close()
            time.sleep(.1)
        else:
            raise RuntimeError('Native application readiness failed; integrate Flux.Server.Assets and rebuild')
        print(f'Flux application URL: http://127.0.0.1:{port} (native, no dev proxy)', flush=True)
        code = process.wait()
        if code:
            raise RuntimeError('Native application exited unsuccessfully')
    finally:
        try:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=40)
                except subprocess.TimeoutExpired:
                    raise RuntimeError('Native application shutdown exceeded deadline')
        finally:
            workspace.stop_group(process)


def install_cli(directory, force=False):
    import shlex
    directory = Path(directory).expanduser().resolve()
    directory.mkdir(parents=True, exist_ok=True)
    target = directory / 'flux'
    if target == (ROOT / 'flux').resolve():
        print('The checkout already provides this launcher: ' + str(target))
        return
    if target.is_dir():
        raise ValueError('Refusing to replace a directory with a CLI launcher: ' + str(target))
    backup = None
    launcher = ('#!/bin/sh\nexec ' + shlex.quote(str(ROOT / 'flux')) + ' "$@"\n').encode()
    if target.exists() or target.is_symlink():
        if target.is_file() and target.read_bytes() == launcher:
            target.chmod(0o755)
            print('Flux CLI already installed: ' + str(target))
            return
        if not force:
            raise ValueError('A different flux command exists at ' + str(target) + '; use --force to back it up and replace it')
        backup = directory / ('flux.backup-' + uuid.uuid4().hex)
        target.rename(backup)
        print('Previous launcher backed up: ' + str(backup))
    try:
        atomic_write(target, launcher)
        target.chmod(0o755)
    except BaseException:
        target.unlink(missing_ok=True)
        if backup is not None:
            backup.rename(target)
        raise
    print('Installed Flux CLI: ' + str(target) + '; ensure this directory is on PATH')


def main():
    # Optional mobile tooling is isolated from server/web dependencies.
    import mobile
    if mobile.dispatch(sys.argv[1:]):
        return
    parser = argparse.ArgumentParser(prog='flux', description=__doc__)
    parser.add_argument('--project', help='application directory (relative to cwd or absolute); otherwise discover flux.json')
    commands = parser.add_subparsers(dest='command', required=True)
    commands.add_parser('new').add_argument('name')
    commands.add_parser('doctor')
    commands.add_parser('mobile', help='optional Capacitor compile/build/sync/run tooling')
    commands.add_parser('generate').add_argument('--check', action='store_true')
    commands.add_parser('build')
    commands.add_parser('check')
    commands.add_parser('sync')
    commands.add_parser('test')
    installer = commands.add_parser('install-cli')
    installer.add_argument('--bin-dir', default='~/.local/bin')
    installer.add_argument('--force', action='store_true')
    launch = commands.add_parser('run', help='start the built native web application; no development proxy or watcher')
    launch.add_argument('--disposable-db', action='store_true')
    launch.add_argument('--port', type=int, default=8090)
    migrate = commands.add_parser('migrate')
    migrate.add_argument('--disposable-db', action='store_true')
    serve = commands.add_parser('dev')
    serve.add_argument('--disposable-db', action='store_true')
    serve.add_argument('--no-build', action='store_true')
    serve.add_argument('--watch', action='store_true', help='watch sources, rebuild safely and live-reload browsers')
    serve.add_argument('--hot', action='store_true', help='opt-in state-preserving DOM UI replacement (implies --watch)')
    serve.add_argument('--port', type=int, default=8090)
    # Accept --project both before and after the subcommand.
    for command in commands.choices.values():
        command.add_argument('--project', default=argparse.SUPPRESS)
    args = parser.parse_args()
    def interrupt(signum, frame):
        # A second Ctrl-C must not interrupt ownership cleanup halfway through.
        signal.signal(signal.SIGINT, signal.SIG_IGN)
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        raise KeyboardInterrupt
    signal.signal(signal.SIGINT, interrupt)
    signal.signal(signal.SIGTERM, interrupt)
    try:
        if args.command == 'install-cli':
            install_cli(args.bin_dir, args.force)
            return
        if args.command == 'new':
            new_project(args.name)
            return
        if args.command == 'doctor':
            workspace.check(workspace.load())
            for tool in ['pack', 'node', 'npm', 'docker', 'curl', 'cc', 'make', 'pkg-config']:
                if not shutil.which(tool):
                    raise ValueError('Missing tool: ' + tool)
            run(['pkg-config', '--atleast-version=3.0.0', 'openssl'], timeout=10)
            run(['pkg-config', '--atleast-version=1.0.18', 'libsodium'], timeout=10)
            run(['pkg-config', '--atleast-version=7.85.0', 'libcurl'], timeout=10)
            run(['docker', 'info', '--format', '{{.ServerVersion}}'], timeout=20)
            run(['node', '-e', 'if(Number(process.versions.node.split(".")[0])<20) process.exit(1)'])
            print('PASS development prerequisites (pack collection: ' + workspace.load()['collection'] + ')')
            return
        project, config = project_config(args.project)
        if args.command == 'sync':
            if application.managed(project, config, ROOT):
                atomic_write(project / 'pack.toml', application.pack_config(project, config, ROOT).encode())
                print('Synchronized application dependencies: ' + str(project / 'pack.toml'))
            else:
                raise ValueError('This application uses the Flux workspace map; use tools/workspace.py sync from the Flux root')
        elif args.command == 'generate':
            application.check_dependencies(project, config, ROOT)
            generate(project, config, args.check)
        elif args.command == 'check':
            application.check_dependencies(project, config, ROOT)
            application.public_files(project, config)
            generate(project, config, check=True)
            print('PASS Flux application configuration, dependencies, browser boundary and generated code')
        elif args.command == 'build':
            build(project, config)
        elif args.command == 'test':
            if not config.get('tests'):
                raise ValueError('No tests configured in flux.json')
            for command in config['tests']:
                run(command, cwd=project)
        else:
            if hasattr(args, 'port') and not 0 <= args.port <= 65535:
                raise ValueError('Port must be between 0 and 65535')
            if args.command == 'dev':
                application.check_dependencies(project, config, ROOT)
                if not args.no_build:
                    build(project, config)
            if config.get('database', 'postgres') == 'none' and args.disposable_db:
                raise ValueError('--disposable-db is not valid for database=none')
            context = database(args.disposable_db) if config.get('database', 'postgres') == 'postgres' else contextlib.nullcontext(dict(os.environ))
            # Reject absent/stale run artifacts before allocating a database.
            if args.command == 'run':
                if not config.get('run', {}).get('web', False):
                    raise ValueError('flux run requires format 2 run.web=true and native Flux.Server.Assets integration')
                application.built_release(project, config)
            with context as env:
                if args.command == 'migrate':
                    binary, env = server_command(project, config, env)
                    run([binary, '--migrate-only'], cwd=project, env=env, timeout=120)
                elif args.command == 'run':
                    run_application(project, config, env, args.port)
                else:
                    env = dict(env)
                    env.pop('FLUX_PUBLIC_DIR', None)
                    with staging_session() as stage:
                        directory, staged_config = stage(project, config)
                        if args.watch or args.hot:
                            dev(directory, staged_config, env, args.port, watch=watch_hooks(project, config, hot=args.hot, stage=stage))
                        else:
                            dev(directory, staged_config, env, args.port)
    except KeyboardInterrupt:
        print('Stopped Flux development session.')
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        # Do not echo subprocess argument lists: Docker arguments contain an
        # ephemeral password. Command output remains available for builds.
        message = type(error).__name__ if isinstance(error, subprocess.SubprocessError) else str(error)
        parser.exit(1, message + '\n')


if __name__ == '__main__':
    main()
