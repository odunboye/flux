"""Full generated Flux UI CRUD, pagination, and migration bootstrap on a disposable DB."""
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parent
name = 'flux-protocol-crud-' + uuid.uuid4().hex[:12]
app = ROOT / 'crud/build/exec/platform-crud-server_app'
created = False
server = None


def docker(*args):
    result = subprocess.run(['docker', *args], timeout=30, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if result.returncode:
        raise RuntimeError(result.stdout)
    return result.stdout.strip()


def sql(statement):
    return docker('exec', name, 'psql', '-U', 'testuser', '-d', 'platform_crud_test',
                  '-v', 'ON_ERROR_STOP=1', '-Atc', statement)


def start(env, log):
    with socket.socket() as reserve:
        reserve.bind(('127.0.0.1', 0))
        port = reserve.getsockname()[1]
    proc = subprocess.Popen([str(app / 'platform-crud-server.so'), str(port), '128'],
                            cwd=ROOT, env=env, stdout=log, stderr=log)
    try:
        for _ in range(200):
            if proc.poll() is not None:
                raise RuntimeError('CRUD server exited during startup')
            try:
                with socket.create_connection(('127.0.0.1', port), timeout=.1):
                    return proc, port
            except OSError:
                time.sleep(.1)
        raise RuntimeError('CRUD server startup timed out')
    except BaseException:
        proc.kill()
        proc.wait()
        raise


def stop(proc):
    proc.terminate()
    try:
        code = proc.wait(timeout=40)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait()
        raise AssertionError('CRUD shutdown timed out')
    assert code == 0, code
    print('PASS CRUD server clean shutdown')


try:
    docker('run', '--pull', 'never', '--rm', '-d', '--name', name,
           '-p', '127.0.0.1::5432', '-e', 'POSTGRES_USER=testuser',
           '-e', 'POSTGRES_PASSWORD=testpass', '-e', 'POSTGRES_DB=platform_crud_test', 'postgres:16')
    created = True
    for _ in range(100):
        try:
            docker('exec', name, 'pg_isready', '-U', 'testuser', '-d', 'platform_crud_test')
            break
        except RuntimeError:
            time.sleep(.2)
    else:
        raise RuntimeError('PostgreSQL startup timed out')
    pgport = docker('port', name, '5432/tcp').rsplit(':', 1)[1]
    env = dict(os.environ, PGHOST='127.0.0.1', PGPORT=pgport, PGUSER='testuser',
               PGPASSWORD='testpass', PGDATABASE='platform_crud_test',
               IDRIS2_INC_SRC=str(app), LD_LIBRARY_PATH=str(app), DYLD_LIBRARY_PATH=str(app),
               FLUX_EVENT_LOOPS='2')
    with tempfile.TemporaryFile() as log:
        try:
            server, port = start(env, log)
            assert sql('SELECT count(*) FROM flux_db_meta.migrations') == '1'
            print('PASS server bootstraps schema through versioned migration')
            sql('ALTER SEQUENCE todos_id_seq RESTART WITH 9223372036854775000')
            sql("INSERT INTO todos(title) SELECT 'seed-' || n::text FROM generate_series(1,55) AS n")
            for target in ['node', 'browser']:
                subprocess.run(['node', str(ROOT / 'run_web_client.cjs'),
                                f'http://127.0.0.1:{port}', 'crud', target],
                               check=True, timeout=120)
                assert sql('SELECT count(*) FROM todos') == '55'
                assert sql("SELECT count(*) FROM todos WHERE title LIKE 'seed-%' AND done = false") == '55'
                print(f'PASS PostgreSQL independently confirms intact seed data after {target} CRUD')
            stop(server)
            server = None
            server, port = start(env, log)
            assert sql('SELECT count(*) FROM todos') == '55'
            assert sql('SELECT count(*) FROM flux_db_meta.migrations') == '1'
            print('PASS restart replays migration safely without resetting application data')
            stop(server)
            server = None
        except BaseException:
            log.seek(0)
            print(log.read().decode(errors='replace'))
            raise
finally:
    if server is not None and server.poll() is None:
        server.kill()
        server.wait()
    if created:
        docker('rm', '-f', '-v', name)
