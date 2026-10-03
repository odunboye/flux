"""Generated Idris/Flux UI -> Flux -> Flux DB -> PG in a disposable database."""
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parent
name = 'flux-protocol-pg-' + uuid.uuid4().hex[:12]
app = ROOT / 'example/build/exec/platform-pg-example_app'
created = False
server = None


def docker(*args, **kwargs):
    return subprocess.run(['docker', *args], check=True, timeout=30,
                          text=True, capture_output=True, **kwargs)


try:
    docker('run', '--pull', 'never', '--rm', '-d', '--name', name,
           '-p', '127.0.0.1::5432', '-e', 'POSTGRES_USER=testuser',
           '-e', 'POSTGRES_PASSWORD=testpass', '-e', 'POSTGRES_DB=platform_test', 'postgres:16')
    created = True
    for _ in range(100):
        try:
            docker('exec', name, 'pg_isready', '-U', 'testuser', '-d', 'platform_test')
            break
        except subprocess.CalledProcessError:
            time.sleep(.2)
    else:
        raise RuntimeError('Postgres startup timed out')
    pgport = docker('port', name, '5432/tcp').stdout.strip().rsplit(':', 1)[1]
    with socket.socket() as reserve:
        reserve.bind(('127.0.0.1', 0))
        port = reserve.getsockname()[1]
    env = dict(os.environ, PGHOST='127.0.0.1', PGPORT=pgport, PGUSER='testuser',
               PGPASSWORD='testpass', PGDATABASE='platform_test',
               IDRIS2_INC_SRC=str(app), LD_LIBRARY_PATH=str(app),
               DYLD_LIBRARY_PATH=str(app), FLUX_EVENT_LOOPS='2')
    # Exercise the renamed persistence package against this owned disposable DB.
    repository_env = dict(env, PG_TEST_HOST='127.0.0.1', PG_TEST_PORT=pgport,
                          PG_TEST_USER='testuser', PG_TEST_PASSWORD='testpass',
                          PG_TEST_DB='platform_test')
    subprocess.run(['python3', str(ROOT.parent / 'packages/db/test/runtime_integration_test.py')],
                   env=repository_env, check=True, timeout=200)
    migration_app = ROOT / 'example/build/exec/platform-migration-test_app'
    migration_env = dict(env, FLUX_DISPOSABLE_TEST='1', IDRIS2_INC_SRC=str(migration_app),
                         LD_LIBRARY_PATH=str(migration_app), DYLD_LIBRARY_PATH=str(migration_app))
    subprocess.run([str(migration_app / 'platform-migration-test.so')],
                   env=migration_env, check=True, timeout=120)
    with tempfile.TemporaryFile() as log:
        server = subprocess.Popen([str(app / 'platform-pg-example.so'), str(port), '128'],
                                  cwd=ROOT, env=env, stdout=log, stderr=log)
        try:
            for _ in range(200):
                if server.poll() is not None:
                    raise RuntimeError('server exited during startup')
                try:
                    with socket.create_connection(('127.0.0.1', port), timeout=.1):
                        break
                except OSError:
                    time.sleep(.1)
            else:
                raise RuntimeError('server startup timed out')
            docker('exec', name, 'psql', '-U', 'testuser', '-d', 'platform_test',
                   '-v', 'ON_ERROR_STOP=1', '-c',
                   'ALTER SEQUENCE todos_id_seq RESTART WITH 9223372036854775000')
            for target in ['node', 'browser']:
                subprocess.run(['node', str(ROOT / 'run_web_client.cjs'),
                                f'http://127.0.0.1:{port}', 'pooled', target],
                               check=True, timeout=120)
            count = docker('exec', name, 'psql', '-U', 'testuser', '-d', 'platform_test',
                           '-Atc', 'SELECT count(*) FROM todos').stdout.strip()
            # Each target creates one round-trip row plus a 24-command batch.
            assert count == '50', count
            print('PASS PostgreSQL independently confirms 50 Flux UI-created rows')
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
                raise AssertionError('server shutdown timed out')
        assert code == 0, code
        print('PASS pooled generated endpoint clean shutdown')
finally:
    if server is not None and server.poll() is None:
        server.kill()
        server.wait()
    if created:
        docker('rm', '-f', '-v', name)
