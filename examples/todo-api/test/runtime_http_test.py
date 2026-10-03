"""Concurrent CRUD through the real pooled server, using the test database.

Run the pooled handler suite first to provision its schema. Only rows created
by this run are mutated or deleted; the test never resets an application DB.
"""
import concurrent.futures
import argparse
import http.client
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time
import threading
import uuid

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--owners', type=int, default=4)
parser.add_argument('--sample', action='store_true')
args = parser.parse_args()
app = ROOT / 'build/exec/todo-api_app'
with socket.socket() as reserve:
    reserve.bind(('127.0.0.1', 0))
    port = reserve.getsockname()[1]
env = dict(os.environ, FLUX_EVENT_LOOPS=str(args.owners),
           PGHOST=os.environ.get('PG_TEST_HOST', '127.0.0.1'),
           PGPORT=os.environ.get('PG_TEST_PORT', '5432'),
           PGUSER=os.environ.get('PG_TEST_USER', 'testuser'),
           PGPASSWORD=os.environ.get('PG_TEST_PASSWORD', 'testpass'),
           PGDATABASE=os.environ.get('PG_TEST_DB', 'todo_api_test'),
           IDRIS2_INC_SRC=str(app), LD_LIBRARY_PATH=str(app), DYLD_LIBRARY_PATH=str(app))
prefix = 'runtime-http-' + uuid.uuid4().hex

def scenario(worker):
    conn = http.client.HTTPConnection('127.0.0.1', port, timeout=20)
    def request(method, path, body=None, expected=200):
        data = None if body is None else json.dumps(body)
        headers = {} if data is None else {'Content-Type': 'application/json'}
        conn.request(method, path, data, headers)
        response = conn.getresponse()
        payload = response.read()
        assert response.status == expected, (method, path, response.status, payload)
        return json.loads(payload) if payload else None
    try:
        for index in range(20):
            title = f'{prefix}-{worker}-{index}'
            todo = request('POST', '/todos', {'title': title}, 201)
            path = '/todos/' + str(todo['id'])
            try:
                assert todo['title'] == title and todo['done'] is False
                assert request('GET', path) == todo
                toggled = request('POST', path + '/toggle')
                assert toggled['id'] == todo['id'] and toggled['done'] is True
                updated = request('PUT', path, {'title': title + '-updated', 'done': False})
                assert updated['title'] == title + '-updated' and updated['done'] is False
                assert request('GET', path) == updated
            finally:
                request('DELETE', path, expected=204)
            request('GET', path, expected=404)
    finally:
        conn.close()

with tempfile.TemporaryFile() as log:
    server = subprocess.Popen([str(app / 'todo-api.so'), str(port), '128'],
                              cwd=ROOT, env=env, stdout=log, stderr=log)
    try:
        for _ in range(200):
            if server.poll() is not None:
                raise RuntimeError('todo-api exited during startup')
            try:
                with socket.create_connection(('127.0.0.1', port), timeout=.1):
                    break
            except OSError:
                time.sleep(.1)
        else:
            raise RuntimeError('todo-api startup timed out')
        started = time.monotonic()
        if args.sample:
            sampler = threading.Timer(1, lambda: subprocess.run(
                ['/usr/bin/sample', str(server.pid), '1', '-file', '/tmp/flux-todo-runtime.sample'],
                timeout=5, check=False, stdout=subprocess.DEVNULL))
            sampler.start()
        with concurrent.futures.ThreadPoolExecutor(max_workers=24) as executor:
            list(executor.map(scenario, range(24)))
        print(f'PASS 24 clients, 480 CRUD lifecycles, 3360 HTTP requests in {time.monotonic() - started:.2f}s')
    except BaseException:
        log.seek(0)
        print(log.read().decode(errors='replace'))
        raise
    finally:
        server.terminate()
        try:
            code = server.wait(timeout=40)
        except subprocess.TimeoutExpired:
            server.kill()
            server.wait()
            raise AssertionError('todo-api did not stop within watchdog deadline')
    assert code == 0, f'todo-api exit code {code}'
    print('PASS pooled todo-api clean shutdown')
