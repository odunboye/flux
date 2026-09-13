"""Unit and process/HTTP acceptance tests for Flux live reload (no Docker)."""
import contextlib
import http.client
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

import devwatch
import flux


def wait_for(predicate, timeout=20):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            value = predicate()
            if value:
                return value
        except (OSError, http.client.HTTPException, json.JSONDecodeError):
            pass
        time.sleep(.1)
    raise AssertionError('Timed out waiting for live reload')


def request(port, path, method='GET', headers=None):
    connection = http.client.HTTPConnection('127.0.0.1', port, timeout=3)
    try:
        connection.request(method, path, body=b'{}' if method == 'POST' else None, headers=headers or {})
        response = connection.getresponse()
        return response.status, response.read()
    finally:
        connection.close()


def fixture(root, port):
    """Separate process: exercise real watcher, compiler ownership and API cutover."""
    root = Path(root)
    config = {'ui': 'ui.ipkg', 'server': 'server.ipkg'}
    def sources():
        return [devwatch.WatchPath(root / 'ui.idr', 'ui'),
                devwatch.WatchPath(root / 'server.idr', 'server'),
                devwatch.WatchPath(root / 'schema.json', 'schema'),
                devwatch.WatchPath(root / 'app.css', 'css'),
                devwatch.WatchPath(root / 'index.html', 'reload')]
    def build(kinds, runner):
        with (root / 'builds.log').open('a') as log:
            log.write(','.join(sorted(kinds)) + '\n')
        if kinds & {'ui', 'both', 'schema'}:
            text = (root / 'ui.idr').read_text()
            # Deliberately corrupt mutable build output to prove snapshot isolation.
            (root / 'build/exec/ui').write_text('incomplete output')
            runner.run([sys.executable, '-c',
                        'import time,sys; time.sleep(.4); print(sys.argv[1]); sys.exit(int(sys.argv[2]))',
                        '<script>unsafe compiler output</script> test-secret', '1' if 'FAIL' in text else '0'])
            (root / 'build/exec/ui').write_text((root / 'source.js').read_text() + '\n//' + text)
        if kinds & {'server', 'both', 'schema'}:
            text = (root / 'server.idr').read_text()
            if 'BADSTART' in text:
                (root / 'build/exec/api_app/api.so').write_text('#!' + sys.executable + '\nraise SystemExit(1)\n')
            else:
                (root / 'build/exec/api_app/api.so').write_text((root / 'api-template').read_text().replace('GENERATION', repr(text)))
            (root / 'build/exec/api_app/api.so').chmod(0o755)
    hooks = devwatch.DevHooks(sources, build, lambda: (root, config))
    def interrupt(*_):
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        signal.signal(signal.SIGINT, signal.SIG_IGN)
        raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, interrupt)
    signal.signal(signal.SIGINT, interrupt)
    try:
        flux.dev(root, config, dict(os.environ, PGPASSWORD='test-secret'), port, watch=hooks)
    except KeyboardInterrupt:
        pass


class WatchUnits(unittest.TestCase):
    def test_snapshot_debounce_inputs_classification_and_exclusions(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            for name in ['UI.idr', 'Server.idr', 'Generated/Client.idr', 'build/exec/out.idr',
                         '.workspace/a.idr', 'node_modules/a.idr', 'public/app.css', 'public/icon.png']:
                path = root / name; path.parent.mkdir(parents=True, exist_ok=True); path.write_text('a')
            paths = [devwatch.WatchPath(root, 'both'), devwatch.WatchPath(root / 'UI.idr', 'ui'),
                     devwatch.WatchPath(root / 'public', 'assets')]
            before = devwatch.snapshot(paths, [root / 'Generated'])
            self.assertEqual(len(before), 4)
            (root / 'UI.idr').write_text('changed')
            self.assertEqual(devwatch.changes(before, devwatch.snapshot(paths, [root / 'Generated'])), {'ui'})
            before = devwatch.snapshot(paths, [root / 'Generated'])
            (root / 'public/app.css').unlink()
            (root / 'public/new.png').write_text('new')
            self.assertEqual(devwatch.changes(before, devwatch.snapshot(paths, [root / 'Generated'])), {'css', 'reload'})
            (root / 'escape.idr').symlink_to(root / 'UI.idr')
            self.assertNotIn(root / 'escape.idr', devwatch.snapshot(paths))

    def test_package_targets_and_transitive_dependencies(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            (root / 'ui.ipkg').write_text('depends = shared\nsourcedir = "src"\nmodules = UI.App,\n Shared.Types\nmain = UI.App\n')
            (root / 'server.ipkg').write_text('depends = db\nsourcedir = "src"\nmodules = Server.Main, Shared.Types\n')
            (root / 'shared').mkdir(); (root / 'db').mkdir()
            (root / 'shared/shared.ipkg').write_text('package shared\n')
            (root / 'db/db.ipkg').write_text('depends = shared\n')
            paths = devwatch.package_sources(root, {'ui': 'ui.ipkg', 'server': 'server.ipkg', 'schema': 'schema.json'},
                                            {'shared': root / 'shared/shared.ipkg', 'db': root / 'db/db.ipkg'})
            mapping = {item.path: item.kind for item in paths}
            self.assertEqual(mapping[root / 'src/UI/App.idr'], 'ui')
            self.assertEqual(mapping[root / 'src/Shared/Types.idr'], 'both')
            self.assertEqual(mapping[root / 'shared'], 'both')
            self.assertEqual(mapping[root / 'db'], 'server')

    def test_native_refresh_does_not_loop_on_manifest_timestamps(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            manifest = root / 'native.ipkg'
            manifest.write_text('prebuild = "make native"\n')
            source = root / 'native.c'; source.write_text('old')
            paths = [devwatch.WatchPath(root, 'server')]
            before = devwatch.snapshot(paths)
            devwatch.refresh_native(paths)
            self.assertEqual(devwatch.changes(before, devwatch.snapshot(paths)), set())
            source.write_text('new native implementation')
            self.assertEqual(devwatch.changes(before, devwatch.snapshot(paths)), {'native', 'server'})

    def test_published_bytes_are_retained_and_versions_are_independent(self):
        state = devwatch.Published()
        state.publish({'/': (b'<head></head>', 'text/html'), '/app.css': (b'old', 'text/css')}, 1234, set())
        state.report(error='<script>bad</script>')
        self.assertEqual(state.asset('/app.css')[0], b'old')
        self.assertIn(b'/__flux_dev/client.js?', state.asset('/')[0])
        state.publish({'/app.css': (b'new', 'text/css')}, 1234, {'css'})
        self.assertEqual((state.status()['css'], state.status()['reload']), (1, 0))
        state.publish({}, 5678, {'ui'})
        self.assertEqual((state.backend(), state.status()['reload'], state.status()['error']), (5678, 1, ''))

    def test_hot_revisions_scope_and_stale_bundle_rejection(self):
        state = devwatch.Published(hot=True)
        assets = {'/': (b'<head></head>', 'text/html'), '/app.js': (b'const x=1;', 'text/javascript')}
        state.publish(assets, 1, set())
        self.assertIn(b'/__flux_dev/hot.js', state.asset('/')[0])
        self.assertTrue(state.asset('/app.js')[0].startswith(b'(() => {'))
        state.publish(assets, 1, {'ui', 'css'})
        self.assertEqual((state.status()['ui'], state.status()['css'], state.status()['reload']), (1, 1, 0))
        self.assertIsNotNone(state.asset('/app.js', '1', '0', state.session))
        self.assertIsNone(state.asset('/app.js', '0', '0', state.session))
        state.publish(assets, 2, {'schema'})
        self.assertEqual(state.status()['reload'], 1)
        self.assertIsNone(state.asset('/app.js', '1', '0', state.session))
        self.assertIsNone(state.asset('/app.js', '1', '1', 'old-session'))

    def test_runner_failure_redaction_timeout_and_cancel(self):
        runner = devwatch.BuildRunner({'PGPASSWORD': 'hidden-secret'})
        with self.assertRaisesRegex(RuntimeError, 'Compilation failed') as caught:
            runner.run([sys.executable, '-c', 'print("hidden-secret");raise SystemExit(2)'])
        self.assertNotIn('hidden-secret', str(caught.exception))
        with self.assertRaisesRegex(RuntimeError, 'timed out'):
            runner.run([sys.executable, '-c', 'import time;time.sleep(20)'], timeout=.1)
        runner.cancelled.set()
        with self.assertRaisesRegex(RuntimeError, 'cancelled'):
            runner.run([sys.executable, '-c', 'raise SystemExit(0)'])


class WatchNative(unittest.TestCase):
    def test_real_chez_runtime_snapshot_and_graceful_drain(self):
        build = flux.ROOT / 'examples/build'
        if not (build / 'exec/flux-examples_app/flux-examples.so').exists():
            self.skipTest('Build examples/examples.ipkg for real native snapshot acceptance')
        with tempfile.TemporaryDirectory(prefix='flux-watch-native-') as directory:
            root = Path(directory)
            (root / 'server.ipkg').write_text('executable = flux-examples\n')
            (root / 'build').symlink_to(build, target_is_directory=True)
            runner = devwatch.BuildRunner(dict(os.environ))
            backends = []
            thread = None
            try:
                for _ in range(2):
                    backend = devwatch.Backend.start(root, {'server': 'server.ipkg'}, dict(os.environ), runner)
                    backends.append(backend)
                    self.assertEqual(request(backend.port, '/')[0], 200)
                result = []
                # This real Flux endpoint sleeps three seconds. An already
                # admitted request must drain while the old generation stops.
                def slow():
                    conn = http.client.HTTPConnection('127.0.0.1', backends[0].port, timeout=10)
                    try:
                        conn.request('GET', '/slow')
                        response = conn.getresponse(); result.append((response.status, response.read()))
                    finally:
                        conn.close()
                thread = threading.Thread(target=slow); thread.start()
                time.sleep(.6)
                backends[0].stop()
                thread.join(timeout=10)
                self.assertFalse(thread.is_alive())
                self.assertEqual(result[0][0], 200)
            finally:
                for backend in backends:
                    backend.stop()
                if thread:
                    thread.join(timeout=10)


class WatchAcceptance(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='flux-watch-test-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        files = {
            'ui.ipkg': 'executable = ui\n', 'server.ipkg': 'executable = api\n',
            'ui.idr': 'initial', 'server.idr': 'initial', 'schema.json': '{}',
            'index.html': '<!doctype html><html><head><meta http-equiv="Content-Security-Policy" content="default-src \'self\'; script-src \'self\'; style-src \'self\'; connect-src \'self\'"><link rel="stylesheet" href="/app.css"></head><body><input aria-label="Draft"><script src="/app.js"></script></body></html>',
            'app.css': 'body{background:rgb(255,255,255)}',
            'source.js': 'window.loads=(window.loads||0)+1;',
            'build/exec/ui': 'window.loads=(window.loads||0)+1;',
            'api-template': '''#!PYTHON
import http.server,sys,os,json,time
from pathlib import Path
with Path('pids.log').open('a') as log: log.write(str(os.getpid())+'\\n')
class Handler(http.server.BaseHTTPRequestHandler):
 def do_POST(self):
  self.rfile.read(int(self.headers.get('Content-Length','0')))
  count=Path('writes'); n=int(count.read_text())+1 if count.exists() else 1; count.write_text(str(n))
  if self.path.endswith('/slow'): time.sleep(3)
  data=json.dumps({'generation':GENERATION,'writes':n}).encode()
  self.send_response(200);self.send_header('Content-Length',str(len(data)));self.end_headers();self.wfile.write(data)
http.server.HTTPServer(('127.0.0.1',int(sys.argv[1])),Handler).serve_forever()
'''.replace('PYTHON', sys.executable),
        }
        for name, text in files.items():
            path = self.root / name; path.parent.mkdir(parents=True, exist_ok=True); path.write_text(text)
        api = self.root / 'build/exec/api_app/api.so'; api.parent.mkdir(parents=True)
        api.write_text(files['api-template'].replace('GENERATION', repr('initial'))); api.chmod(0o755)
        import socket
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0)); self.port = sock.getsockname()[1]
        self.log = (self.root / 'watch.log').open('w')
        self.process = subprocess.Popen([sys.executable, __file__, '--fixture', str(self.root), str(self.port)],
                                        stdout=self.log, stderr=subprocess.STDOUT, start_new_session=True)
        self.addCleanup(self.stop)
        wait_for(lambda: self.status())

    def stop(self):
        if self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=15)
            except subprocess.TimeoutExpired:
                flux.workspace.stop_group(self.process)
                self.fail('Watcher did not terminate cleanly')
        self.log.close()

    def status(self):
        return json.loads(request(self.port, '/__flux_dev/status')[1])

    def edit(self, name, value):
        (self.root / name).write_text(value)

    def test_live_publication_failed_build_recovery_and_backend_restart(self):
        old_js = request(self.port, '/app.js')[1]
        self.edit('app.css', 'body{background:rgb(1,2,3)}')
        wait_for(lambda: self.status()['css'] == 1)
        self.assertEqual(self.status()['reload'], 0)
        self.edit('ui.idr', 'FAIL')
        error = wait_for(lambda: self.status()['error'])
        self.assertIn('Compilation failed', error)
        self.assertNotIn('test-secret', error)
        self.assertEqual(request(self.port, '/app.js')[1], old_js)
        self.edit('ui.idr', 'fixed')
        wait_for(lambda: self.status()['reload'] == 1)
        self.assertIn(b'fixed', request(self.port, '/app.js')[1])
        self.assertEqual(self.status()['error'], '')
        self.assertEqual(json.loads(request(self.port, '/rpc/v1/write', 'POST')[1])['writes'], 1)
        self.edit('server.idr', 'BADSTART')
        wait_for(lambda: 'Candidate API exited' in self.status()['error'])
        self.assertEqual(self.status()['reload'], 1)
        self.assertEqual(json.loads(request(self.port, '/rpc/v1/write', 'POST')[1])['generation'], 'initial')
        self.edit('server.idr', 'next')
        wait_for(lambda: self.status()['reload'] == 2)
        result = json.loads(request(self.port, '/rpc/v1/write', 'POST')[1])
        self.assertEqual(result, {'generation': 'next', 'writes': 3})
        self.edit('schema.json', '{"new":true}')
        wait_for(lambda: self.status()['reload'] == 3)
        self.assertIn('schema', (self.root / 'builds.log').read_text())
        self.stop()
        for pid in (self.root / 'pids.log').read_text().splitlines():
            with self.assertRaises(ProcessLookupError): os.kill(int(pid), 0)

    def test_interrupted_write_is_not_replayed_during_cutover(self):
        result = []
        thread = threading.Thread(target=lambda: result.append(request(self.port, '/rpc/v1/slow', 'POST')))
        thread.start()
        try:
            wait_for(lambda: (self.root / 'writes').exists())
            self.edit('server.idr', 'replacement')
            wait_for(lambda: self.status()['reload'] == 1)
            thread.join(timeout=5)
            self.assertFalse(thread.is_alive())
            self.assertEqual(result[0][0], 502)
            self.assertEqual((self.root / 'writes').read_text(), '1')
        finally:
            thread.join(timeout=5)

    def test_rapid_saves_supersede_build_and_generated_output_does_not_loop(self):
        self.edit('ui.idr', 'first')
        wait_for(lambda: self.status()['building'])
        self.edit('ui.idr', 'second')
        wait_for(lambda: self.status()['reload'] == 1)
        self.assertIn(b'second', request(self.port, '/app.js')[1])
        time.sleep(1)
        self.assertEqual(self.status()['reload'], 1)
        self.assertEqual(len((self.root / 'builds.log').read_text().splitlines()), 2)

    def test_deleted_source_recovers_without_restarting_watcher(self):
        (self.root / 'ui.idr').unlink()
        wait_for(lambda: self.status()['error'])
        self.assertEqual(self.status()['reload'], 0)
        self.edit('ui.idr', 'restored')
        wait_for(lambda: self.status()['reload'] == 1)
        self.assertEqual(self.status()['error'], '')

    def test_stop_during_build_reaps_compiler_and_api(self):
        self.edit('ui.idr', 'new')
        wait_for(lambda: self.status()['building'])
        self.stop()
        self.assertEqual(self.process.returncode, 0)
        for pid in (self.root / 'pids.log').read_text().splitlines():
            with self.assertRaises(ProcessLookupError): os.kill(int(pid), 0)

    def test_dev_routes_security_and_no_instrumentation_without_watch(self):
        for path in ['/src/UI.idr', '/ui.idr', '/schema.json', '/watch.log', '/../server.ipkg', '/__flux_dev/unknown']:
            self.assertEqual(request(self.port, path)[0], 404)
        for path in ['/__flux_dev/status', '/', '/__flux_dev/client.js']:
            self.assertEqual(request(self.port, path, headers={'Host': 'evil.example'})[0], 403)
            self.assertEqual(request(self.port, path, headers={'Origin': 'https://evil.example'})[0], 403)
        self.assertIn(b'/__flux_dev/client.js', request(self.port, '/')[1])
        import http.server
        server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), flux.handler(self.root, {'ui': 'ui.ipkg'}, 1))
        thread = threading.Thread(target=server.serve_forever); thread.start()
        try:
            self.assertEqual(request(server.server_port, '/__flux_dev/status')[0], 404)
            self.assertNotIn(b'/__flux_dev/client.js', request(server.server_port, '/')[1])
        finally:
            server.shutdown(); server.server_close(); thread.join()

    def test_browser_css_state_overlay_reload_and_reconnect(self):
        script = Path(__file__).parent / 'dev/test_browser.cjs'
        if not (flux.ROOT / 'packages/ui/node_modules/@playwright/test').exists():
            self.skipTest('Install packages/ui Playwright dependencies for browser acceptance')
        subprocess.run(['node', str(script), str(self.port), str(self.root)], check=True, timeout=45)


if __name__ == '__main__':
    if len(sys.argv) > 1 and sys.argv[1] == '--fixture':
        fixture(sys.argv[2], int(sys.argv[3]))
    else:
        unittest.main()
