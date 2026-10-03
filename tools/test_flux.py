import json
import os
import contextlib
import io
import http.client
import http.server
import threading
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import flux
import workspace


class FluxTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        previous_cwd = Path.cwd()
        os.chdir(self.root)
        self.addCleanup(os.chdir, previous_cwd)
        original = flux.ROOT
        manifest = workspace.load()
        for path in set(manifest['packages'].values()) | {
                'workspace.json', 'pack.toml', 'platform/generate.py'} | {
                'platform/crud/' + name for name in flux.TEMPLATE_FILES}:
            target = self.root / path
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(original / path, target)
        for module in [flux, workspace]:
            patcher = patch.object(module, 'ROOT', self.root)
            patcher.start()
            self.addCleanup(patcher.stop)
        self.before = (self.root / 'workspace.json').read_bytes()
        # CLI lifecycle tests mock execution, but stage real fixture artifacts.
        project = self.root / 'platform/crud'
        native = project / 'build/exec/platform-crud-server_app/platform-crud-server.so'
        native.parent.mkdir(parents=True)
        native.write_bytes(b'fixture native artifact')
        (project / 'build/exec/flux-todo-web').write_bytes(b'fixture UI artifact')

    def test_proxy_forwards_one_bounded_bearer_and_no_cookies(self):
        received = []
        class Backend(http.server.BaseHTTPRequestHandler):
            def log_message(self, *args): pass
            def do_POST(self):
                self.rfile.read(int(self.headers['Content-Length']))
                received.append(dict(self.headers))
                self.send_response(200)
                self.send_header('Content-Length', '2')
                self.end_headers()
                self.wfile.write(b'{}')
        backend = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Backend)
        proxy = http.server.ThreadingHTTPServer(('127.0.0.1', 0), flux.handler(
            self.root / 'platform/crud', {'ui': 'ui.ipkg'}, backend.server_port))
        threads = [threading.Thread(target=s.serve_forever) for s in [backend, proxy]]
        for thread in threads: thread.start()
        try:
            def request(values, origin=None):
                conn = http.client.HTTPConnection('127.0.0.1', proxy.server_port, timeout=2)
                try:
                    conn.putrequest('POST', '/rpc/v1/auth/me')
                    conn.putheader('Content-Length', '2')
                    conn.putheader('Cookie', 'not-forwarded')
                    for value in values: conn.putheader('Authorization', value)
                    if origin: conn.putheader('Origin', origin)
                    conn.endheaders(b'{}')
                    response = conn.getresponse(); response.read()
                    return response.status
                finally: conn.close()
            token = 'Bearer ' + 'a'*43
            self.assertEqual(request([token]), 200)
            self.assertEqual(received[-1]['Authorization'], token)
            self.assertNotIn('Cookie', received[-1])
            for credentials in [[token, token], ['Bearer short'], ['Basic '+ 'a'*43], [token+',x']]:
                self.assertEqual(request(credentials), 400)
            self.assertEqual(request([token], 'https://untrusted.example'), 403)
            self.assertEqual(len(received), 1)
        finally:
            for server in [proxy, backend]: server.shutdown(); server.server_close()
            for thread in threads:
                thread.join(timeout=3)
                self.assertFalse(thread.is_alive())

    def test_create_and_register(self):
        flux.new_project('sample')
        project, config = flux.project_config('apps/sample')
        flux.generate(project, config, check=True)
        manifest = workspace.load()
        self.assertIn('sample-ui', manifest['browser_roots'])
        self.assertEqual(manifest['packages']['sample-ui'], 'apps/sample/ui.ipkg')
        self.assertIn('package sample-server', (project / 'server.ipkg').read_text())
        workspace.check(manifest)

    def test_names_and_existing_directories_are_safe(self):
        for name in ['../escape', '/tmp/escape', 'Some App', '', 'x' * 49, 'todo-api', 'trailing-', 'two--hyphens']:
            with self.subTest(name=name), self.assertRaises(ValueError):
                flux.new_project(name)
        self.assertEqual((self.root / 'workspace.json').read_bytes(), self.before)

    def test_generation_failure_rolls_back(self):
        with patch.object(flux, 'generate', side_effect=RuntimeError('generation failed')):
            with self.assertRaisesRegex(RuntimeError, 'generation failed'):
                flux.new_project('broken')
        self.assertFalse((self.root / 'apps/broken').exists())
        self.assertEqual((self.root / 'workspace.json').read_bytes(), self.before)
        workspace.check(workspace.load())

    def test_map_failure_rolls_back(self):
        original = flux.atomic_write
        count = 0
        def fail_once(path, data):
            nonlocal count
            count += 1
            if count == 2:
                raise OSError('map failed')
            original(path, data)
        with patch.object(flux, 'atomic_write', side_effect=fail_once):
            with self.assertRaisesRegex(OSError, 'map failed'):
                flux.new_project('broken')
        self.assertFalse((self.root / 'apps/broken').exists())
        self.assertEqual((self.root / 'workspace.json').read_bytes(), self.before)
        workspace.check(workspace.load())

    def test_project_paths_cannot_escape(self):
        with self.assertRaises(OSError):
            flux.project_config('../outside')
        path = self.root / 'platform/crud/flux.json'
        config = json.loads(path.read_text())
        config['schema'] = '../../workspace.json'
        path.write_text(json.dumps(config))
        with self.assertRaises(ValueError):
            flux.project_config('platform/crud')

    def test_subprocess_deadline(self):
        with self.assertRaises(subprocess.TimeoutExpired):
            flux.run([sys.executable, '-c', 'import time; time.sleep(30)'], timeout=.1)

    def docker_stub(self, calls, removal_error=None):
        def invoke(args, **kwargs):
            calls.append(args)
            if args[1] == 'rm' and removal_error is not None:
                raise removal_error(args)
            output = '127.0.0.1:54321' if args[1] == 'port' else ''
            return subprocess.CompletedProcess(args, 0, output, '')
        return invoke

    def test_disposable_removal_success_and_body_failure(self):
        for body_fails in [False, True]:
            with self.subTest(body_fails=body_fails):
                calls = []
                with patch.object(flux, 'run', side_effect=self.docker_stub(calls)), \
                     patch.object(subprocess, 'run', side_effect=AssertionError('Unchecked subprocess invoked')):
                    def session():
                        with flux.database(True):
                            if body_fails:
                                raise ValueError('session failed')
                    if body_fails:
                        with self.assertRaisesRegex(ValueError, 'session failed'):
                            session()
                    else:
                        session()
                launch = next(cmd for cmd in calls if cmd[1] == 'run')
                name = launch[launch.index('--name') + 1]
                self.assertEqual(calls[-1], ['docker', 'rm', '-f', '-v', name])

    def test_disposable_removal_failure_is_reported(self):
        failures = [
            lambda args: subprocess.CalledProcessError(1, args, stderr='daemon refused removal'),
            lambda args: subprocess.TimeoutExpired(args, 60, stderr=b'daemon timed out'),
            lambda args: OSError('Docker unavailable'),
        ]
        for failure in failures:
            for body_fails in [False, True]:
                with self.subTest(failure=failure, body_fails=body_fails):
                    calls = []
                    with patch.object(flux, 'run', side_effect=self.docker_stub(calls, failure)), \
                         patch.object(subprocess, 'run', side_effect=AssertionError('Unchecked subprocess invoked')):
                        with self.assertRaises(RuntimeError) as caught:
                            with flux.database(True) as env:
                                if body_fails:
                                    raise ValueError('session failed')
                    launch = next(cmd for cmd in calls if cmd[1] == 'run')
                    name = launch[launch.index('--name') + 1]
                    self.assertEqual(calls[-1], ['docker', 'rm', '-f', '-v', name])
                    message = str(caught.exception)
                    self.assertIn(name, message)
                    self.assertIn('data may remain', message)
                    self.assertIn('docker rm -f -v ' + name, message)
                    cause = caught.exception.__cause__
                    diagnostic = getattr(cause, 'stderr', None) or str(cause)
                    if isinstance(diagnostic, bytes):
                        diagnostic = diagnostic.decode()
                    self.assertIn(diagnostic, message)
                    self.assertNotIn(env['PGPASSWORD'], message)

    def test_cli_fails_when_disposable_removal_fails(self):
        calls = []
        failure = lambda args: subprocess.CalledProcessError(1, args, stderr='daemon refused removal')
        stderr = io.StringIO()
        with patch.object(flux, 'run', side_effect=self.docker_stub(calls, failure)), \
             patch.object(flux, 'dev'), patch.object(flux.signal, 'signal'), \
             patch.object(subprocess, 'run', side_effect=AssertionError('Unchecked subprocess invoked')), \
             patch.object(sys, 'argv', ['flux', 'dev', '--no-build', '--disposable-db']), \
             contextlib.redirect_stderr(stderr):
            with self.assertRaises(SystemExit) as caught:
                flux.main()
        self.assertEqual(caught.exception.code, 1)
        self.assertIn(calls[-1][-1], stderr.getvalue())
        self.assertIn('daemon refused removal', stderr.getvalue())

    def test_watch_build_targets_and_generated_exclusions(self):
        project, config = flux.project_config('platform/crud')
        hooks = flux.watch_hooks(project, config)
        class Runner:
            def __init__(self): self.calls = []
            def run(self, args, **kwargs): self.calls.append(args)
        runner = Runner()
        hooks.build({'css'}, runner)
        self.assertEqual(runner.calls, [])
        hooks.build({'ui'}, runner)
        self.assertTrue(any('javascript' in call for call in runner.calls))
        self.assertFalse(any(str(project / config['server']) in call for call in runner.calls))
        runner.calls.clear()
        hooks.build({'schema'}, runner)
        self.assertTrue(any(str(project / config['server']) in call for call in runner.calls))
        self.assertTrue(any('javascript' in call for call in runner.calls))
        self.assertIn(project / 'Client.idr', hooks.exclude())

    def test_cli_watch_passes_framework_hooks(self):
        calls = []
        with patch.object(flux, 'run', side_effect=self.docker_stub(calls)), \
             patch.object(flux, 'dev') as dev, patch.object(flux.signal, 'signal'), \
             patch.object(sys, 'argv', ['flux', 'dev', '--watch', '--no-build', '--disposable-db']):
            flux.main()
        self.assertIn('watch', dev.call_args.kwargs)
        self.assertEqual(calls[-1][1], 'rm')

    def test_database_requires_explicit_configuration(self):
        with patch.dict('os.environ', {}, clear=True):
            with self.assertRaisesRegex(ValueError, 'PGHOST'):
                with flux.database(False):
                    self.fail('should not supply a default database')


if __name__ == '__main__':
    unittest.main()
