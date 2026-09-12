"""Fresh workspace -> CLI new/build/migrate/dev -> real Flux UI -> independent DB checks."""
import os
import json
import signal
import urllib.request
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]


def run(args, **kwargs):
    return subprocess.run(args, check=True, timeout=kwargs.pop('timeout', 120), **kwargs)


def main():
    name = 'flux-ui-test-' + uuid.uuid4().hex
    server = None
    def docker(*args):
        return run(['docker', *args], timeout=60, text=True, stdout=subprocess.PIPE,
                   stderr=subprocess.PIPE).stdout.strip()
    def sql(statement):
        return docker('exec', name, 'psql', '-U', 'testuser', '-d', 'testdb',
                      '-v', 'ON_ERROR_STOP=1', '-Atc', statement)
    with tempfile.TemporaryDirectory(prefix='flux-app-check-') as folder:
        export = Path(folder) / 'flux'
        # No sibling repositories, build artifacts, global UI demo or Git
        # metadata are copied. Browser tooling runs from this test's checkout.
        shutil.copytree(ROOT, export, ignore=shutil.ignore_patterns(
            '.git', 'build', 'node_modules', '.workspace', '__pycache__',
            'reports', 'test-results', 'playwright-report', 'app.js',
            '*.ttc', '*.ttm', '*.so', '*.dylib', '*.o', '*.a'))
        cli = [str(export / 'flux')]
        run(cli + ['new', 'acceptance'], cwd=export)
        project_cli = cli + ['--project', 'apps/acceptance']
        run(project_cli + ['generate', '--check'], cwd=export)
        run(project_cli + ['build'], cwd=export, timeout=600)
        try:
            docker('run', '--rm', '-d', '--name', name, '-p', '127.0.0.1::5432',
                   '-e', 'POSTGRES_USER=testuser', '-e', 'POSTGRES_PASSWORD=testpass',
                   '-e', 'POSTGRES_DB=testdb', 'postgres:16')
            for _ in range(150):
                try:
                    docker('exec', name, 'pg_isready', '-h', '127.0.0.1', '-U', 'testuser', '-d', 'testdb')
                    break
                except subprocess.CalledProcessError:
                    time.sleep(.2)
            else:
                raise RuntimeError('DB startup timed out')
            env = dict(os.environ, PGHOST='127.0.0.1', PGPORT=docker('port', name, '5432/tcp').rsplit(':', 1)[1],
                       PGUSER='testuser', PGPASSWORD='testpass', PGDATABASE='testdb')
            for _ in range(2):
                run(project_cli + ['migrate'], env=env, cwd=export)
            assert sql('SELECT count(*) FROM flux_db_meta.migrations') == '3'
            sql('ALTER SEQUENCE private_todos_id_seq RESTART WITH 9223372036854775000')
            for mode in ['lifecycle', 'pagination']:
                with tempfile.TemporaryFile(mode='w+') as log:
                    server = subprocess.Popen(project_cli + ['dev', '--no-build', '--port', '0'],
                                              cwd=export, env=env, stdout=log, stderr=log)
                    try:
                        for _ in range(300):
                            log.seek(0)
                            output = log.read()
                            match = re.search(r'Flux development URL: (http://127.0.0.1:\d+)', output)
                            if match:
                                break
                            if server.poll() is not None:
                                raise RuntimeError('CLI exited: ' + output)
                            time.sleep(.1)
                        else:
                            raise RuntimeError('CLI readiness timed out: ' + output)
                        run(['node', str(ROOT / 'platform/test_app.cjs'), match[1], mode])
                        if mode == 'lifecycle':
                            run(['node', str(ROOT / 'platform/test_private_app.cjs'), match[1]])
                            assert sql("SELECT count(*) FROM private_todos WHERE owner_id=(SELECT id FROM flux_auth_accounts WHERE username='browser_owner_a')") == '2'
                            assert sql("SELECT count(*) FROM private_todos WHERE owner_id=(SELECT id FROM flux_auth_accounts WHERE username='browser_owner_b')") == '1'
                    except BaseException:
                        log.seek(0)
                        print(log.read())
                        raise
                    finally:
                        server.terminate()
                        try:
                            assert server.wait(timeout=50) == 0
                        except subprocess.TimeoutExpired:
                            server.kill()
                            server.wait()
                            raise
                        server = None
                owner = sql("SELECT id FROM flux_auth_accounts WHERE username='cli_account'")
                assert sql(f"SELECT count(*) FROM private_todos WHERE owner_id={owner} AND title = 'Persisted UI 🚀' AND done = true") == '1'
                assert sql('SELECT count(*) FROM flux_db_meta.migrations') == '3'
                if mode == 'lifecycle':
                    assert sql(f'SELECT count(*) FROM private_todos WHERE owner_id={owner}') == '1'
                    sql(f"INSERT INTO private_todos(owner_id,title) SELECT {owner},'seed-' || n::text FROM generate_series(1,55) AS n")
                else:
                    assert sql(f'SELECT count(*) FROM private_todos WHERE owner_id={owner}') == '56'
                print('PASS independent PostgreSQL UI persistence and clean CLI shutdown:', mode)
            # Explicit disposable mode must own/remove only its new database,
            # even when persistent PG configuration is present in the environment.
            with tempfile.TemporaryFile(mode='w+') as log:
                server = subprocess.Popen(project_cli + ['dev', '--no-build', '--port', '0', '--disposable-db'],
                                          cwd=export, env=env, stdout=log, stderr=log)
                try:
                    for _ in range(400):
                        log.seek(0)
                        output = log.read()
                        match = re.search(r'Flux development URL: (http://127.0.0.1:\d+)', output)
                        if match:
                            break
                        if server.poll() is not None:
                            raise RuntimeError(output)
                        time.sleep(.1)
                    else:
                        raise RuntimeError('Disposable CLI readiness timed out: ' + output)
                    owned = re.search(r'Disposable development database (flux-dev-[a-f0-9]+):', output)[1]
                    def rpc(path, body, token=None):
                        headers = {'Content-Type':'application/json'}
                        if token: headers['Authorization'] = 'Bearer ' + token
                        request = urllib.request.Request(match[1] + '/rpc/v1/' + path,
                            data=json.dumps(body).encode(), headers=headers)
                        with urllib.request.urlopen(request,timeout=12) as response:
                            return json.load(response)
                    credentials = {'username':'disposable_user','password':'Disposable correct horse battery'}
                    rpc('auth/register',credentials)
                    token = rpc('auth/login',credentials)['token']
                    assert rpc('todos/list',{'afterId':None},token)['todos'] == []
                finally:
                    server.terminate()
                    try:
                        assert server.wait(timeout=120) == 0
                    except subprocess.TimeoutExpired:
                        server.kill()
                        server.wait()
                        raise
                    server = None
                assert docker('ps', '-a', '--filter', 'name=^' + owned + '$', '--format', '{{.Names}}') == ''
                assert sql(f'SELECT count(*) FROM private_todos WHERE owner_id={owner}') == '56'
                print('PASS CLI removes its disposable database and preserves the explicitly configured database')
        finally:
            if server is not None and server.poll() is None:
                server.kill()
                server.wait()
            subprocess.run(['docker', 'rm', '-f', '-v', name], timeout=60,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    print('PASS fresh-source project CLI and complete Flux UI application acceptance')


if __name__ == '__main__':
    def interrupt(signum, frame):
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        signal.signal(signal.SIGINT, signal.SIG_IGN)
        raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, interrupt)
    signal.signal(signal.SIGINT, interrupt)
    main()
