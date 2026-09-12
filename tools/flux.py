#!/usr/bin/env python3
"""Flux workspace application CLI (development preview, standard-library only)."""
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

import workspace

ROOT = Path(__file__).resolve().parents[1]
TEMPLATE_FILES = ['Main.idr', 'TodoUI.idr', 'MainWeb.idr', 'server.ipkg', 'ui.ipkg',
                  'schema.json', 'flux.json', 'index.html', 'app.css']


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


def project_config(path):
    project = (ROOT / path).resolve()
    project.relative_to(ROOT)
    config = json.loads((project / 'flux.json').read_text())
    if (not isinstance(config, dict) or set(config) != {'format', 'schema', 'server', 'ui'}
            or type(config['format']) is not int or config['format'] != 1):
        raise ValueError('Unsupported flux.json; expected format, schema, server and ui')
    for key in ['schema', 'server', 'ui']:
        if not isinstance(config[key], str) or not config[key]:
            raise ValueError(f'Expected a relative filename for {key}')
        if Path(config[key]).is_absolute():
            raise ValueError(f'Expected a relative filename for {key}')
        child = (project / config[key]).resolve()
        child.relative_to(project)
        if not child.is_file():
            raise ValueError(f'Missing project {key}')
    return project, config


def generate(project, config, check=False):
    run([sys.executable, str(ROOT / 'platform/generate.py'), str(project / config['schema']),
         '--out', str(project)] + (['--check'] if check else []))


def build(project, config):
    generate(project, config, check=True)
    run(['pack', '--no-prompt', 'build', str(project / config['server'])], cwd=ROOT)
    run(['pack', '--no-prompt', 'install', 'flux-ui'], cwd=ROOT)
    run(['pack', '--no-prompt', '--cg', 'javascript', 'build', str(project / config['ui'])], cwd=ROOT)


def executable(project, manifest):
    text = (project / manifest).read_text()
    match = re.search(r'^executable\s*=\s*([a-zA-Z0-9_-]+)\s*$', text, re.M)
    if not match:
        raise ValueError('Expected a simple executable name in ' + manifest)
    return match[1]


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
    try:
        docker('run', '--rm', '-d', '--name', name, '-p', '127.0.0.1::5432',
               '-e', 'POSTGRES_USER=fluxdev', '-e', 'POSTGRES_PASSWORD=' + password,
               '-e', 'POSTGRES_DB=fluxdev', 'postgres:16')
        for _ in range(150):
            try:
                docker('exec', name, 'pg_isready', '-U', 'fluxdev', '-d', 'fluxdev')
                break
            except subprocess.CalledProcessError:
                time.sleep(.2)
        else:
            raise RuntimeError('Disposable PostgreSQL did not become ready')
        port = docker('port', name, '5432/tcp').rsplit(':', 1)[1]
        print(f'Disposable development database {name}: removed on exit; no persistent data.', flush=True)
        yield dict(os.environ, PGHOST='127.0.0.1', PGPORT=port, PGUSER='fluxdev',
                   PGPASSWORD=password, PGDATABASE='fluxdev')
    finally:
        try:
            docker('rm', '-f', '-v', name)
        except (OSError, subprocess.SubprocessError) as error:
            diagnostic = getattr(error, 'stderr', None) or getattr(error, 'stdout', None) or str(error)
            if isinstance(diagnostic, bytes):
                diagnostic = diagnostic.decode(errors='replace')
            # Use RuntimeError so main reports this diagnostic rather than
            # redacting it as a generic subprocess error. Only removal output
            # is included here, never the launch arguments containing a password.
            raise RuntimeError(
                f'Failed to remove disposable database container {name}; data may remain. '
                f'Retry: docker rm -f -v {name}. Docker: {diagnostic.strip()}'
            ) from error


def server_command(project, config, env):
    name = executable(project, config['server'])
    app = project / 'build/exec' / (name + '_app')
    binary = app / (name + '.so')
    if not binary.is_file():
        raise ValueError('Server not built; run flux.py build first')
    return str(binary), dict(env, IDRIS2_INC_SRC=str(app), LD_LIBRARY_PATH=str(app),
                             DYLD_LIBRARY_PATH=str(app))


def handler(project, config, backend):
    assets = {'/': (project / 'index.html', 'text/html; charset=utf-8'),
              '/app.css': (project / 'app.css', 'text/css; charset=utf-8'),
              '/app.js': (project / 'build/exec' / executable(project, config['ui']), 'text/javascript; charset=utf-8')}
    class Handler(http.server.BaseHTTPRequestHandler):
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
            asset = assets.get(self.path)
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
            conn = http.client.HTTPConnection('127.0.0.1', backend, timeout=12)
            try:
                data = self.rfile.read(length)
                if len(data) != length:
                    self.reply(400, b'Truncated body', 'text/plain')
                    return
                conn.request('POST', self.path, data, {'Content-Type': 'application/json'})
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


def dev(project, config, env, port):
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


def main():
    parser = argparse.ArgumentParser(prog='flux', description=__doc__)
    parser.add_argument('--project', default='platform/crud', help='workspace-relative application directory')
    commands = parser.add_subparsers(dest='command', required=True)
    commands.add_parser('new').add_argument('name')
    commands.add_parser('doctor')
    commands.add_parser('generate').add_argument('--check', action='store_true')
    commands.add_parser('build')
    migrate = commands.add_parser('migrate')
    migrate.add_argument('--disposable-db', action='store_true')
    serve = commands.add_parser('dev')
    serve.add_argument('--disposable-db', action='store_true')
    serve.add_argument('--no-build', action='store_true')
    serve.add_argument('--port', type=int, default=8090)
    args = parser.parse_args()
    def interrupt(signum, frame):
        # A second Ctrl-C must not interrupt ownership cleanup halfway through.
        signal.signal(signal.SIGINT, signal.SIG_IGN)
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        raise KeyboardInterrupt
    signal.signal(signal.SIGINT, interrupt)
    signal.signal(signal.SIGTERM, interrupt)
    try:
        if args.command == 'new':
            new_project(args.name)
            return
        if args.command == 'doctor':
            workspace.check(workspace.load())
            for tool in ['pack', 'node', 'npm', 'docker', 'curl']:
                if not shutil.which(tool):
                    raise ValueError('Missing tool: ' + tool)
            run(['docker', 'info', '--format', '{{.ServerVersion}}'], timeout=20)
            run(['node', '-e', 'if(Number(process.versions.node.split(".")[0])<20) process.exit(1)'])
            print('PASS development prerequisites (pack collection: ' + workspace.load()['collection'] + ')')
            return
        project, config = project_config(args.project)
        if args.command == 'generate':
            generate(project, config, args.check)
        elif args.command == 'build':
            build(project, config)
        else:
            if args.command == 'dev' and not args.no_build:
                build(project, config)
            with database(args.disposable_db) as env:
                if args.command == 'migrate':
                    binary, env = server_command(project, config, env)
                    run([binary, '--migrate-only'], cwd=project, env=env, timeout=120)
                else:
                    if not 0 <= args.port <= 65535:
                        raise ValueError('Port must be between 0 and 65535')
                    dev(project, config, env, args.port)
    except KeyboardInterrupt:
        print('Stopped Flux development session.')
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        # Do not echo subprocess argument lists: Docker arguments contain an
        # ephemeral password. Command output remains available for builds.
        message = type(error).__name__ if isinstance(error, subprocess.SubprocessError) else str(error)
        parser.exit(1, message + '\n')


if __name__ == '__main__':
    main()
