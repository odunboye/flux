"""Real PG upgrade, private generated clients, isolation and revocation acceptance."""
import os
import http.client
import json
import hashlib
from concurrent.futures import ThreadPoolExecutor
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
    result = subprocess.run(['docker', *args], timeout=45, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if result.returncode: raise RuntimeError(result.stdout)
    return result.stdout.strip()


def sql(statement):
    return docker('exec', name, 'psql', '-U', 'testuser', '-d', 'platform_crud_test',
                  '-v', 'ON_ERROR_STOP=1', '-Atc', statement)


def start(env, log, legacy=False):
    with socket.socket() as reserve:
        reserve.bind(('127.0.0.1', 0)); port = reserve.getsockname()[1]
    binary = ROOT.parent / 'packages/auth/test/build/exec/flux-auth-integration-test_app/flux-auth-integration-test.so' if legacy else app / 'platform-crud-server.so'
    scope = dict(env, IDRIS2_INC_SRC=str(binary.parent), LD_LIBRARY_PATH=str(binary.parent), DYLD_LIBRARY_PATH=str(binary.parent))
    proc = subprocess.Popen([str(binary), str(port), '128'], cwd=ROOT, env=scope, stdout=log, stderr=log)
    try:
        for _ in range(200):
            if proc.poll() is not None: raise RuntimeError('CRUD server exited during startup')
            try:
                with socket.create_connection(('127.0.0.1', port), timeout=.1): return proc, port
            except OSError: time.sleep(.1)
        raise RuntimeError('CRUD startup timed out')
    except BaseException:
        proc.kill(); proc.wait(); raise


def stop(proc):
    proc.terminate()
    try: code = proc.wait(timeout=40)
    except subprocess.TimeoutExpired:
        proc.kill(); proc.wait(); raise AssertionError('CRUD shutdown timed out')
    assert code == 0, code


def call(path, data=None, token=None, expected=200):
    conn = http.client.HTTPConnection('127.0.0.1', port, timeout=15)
    try:
        headers = {'Content-Type':'application/json'}
        if token: headers['Authorization'] = 'Bearer ' + token
        conn.request('POST', '/rpc/v1/' + path, json.dumps(data or {}), headers)
        response = conn.getresponse(); value = json.loads(response.read())
        assert response.status == expected, (path,response.status,value)
        assert response.getheader('Cache-Control') == 'no-store'
        assert response.getheader('Access-Control-Allow-Origin') is None
        return value
    finally: conn.close()


def account(name):
    data = {'username':name,'password':'Generated client test secret!'}
    user = call('auth/register', data)
    return user['id'], call('auth/login', data)['token']


def ready_db():
    for _ in range(100):
        try:
            docker('exec', name, 'pg_isready', '-h', '127.0.0.1', '-U', 'testuser', '-d', 'platform_crud_test'); return
        except RuntimeError: time.sleep(.2)
    raise RuntimeError('PostgreSQL startup timed out')


try:
    with socket.socket() as reserve:
        reserve.bind(('127.0.0.1',0)); published_port=reserve.getsockname()[1]
    docker('run', '--pull', 'never', '--rm', '-d', '--name', name,
           '-p', f'127.0.0.1:{published_port}:5432', '-e', 'POSTGRES_USER=testuser',
           '-e', 'POSTGRES_PASSWORD=testpass', '-e', 'POSTGRES_DB=platform_crud_test', 'postgres:16')
    created = True
    ready_db()
    pgport = docker('port', name, '5432/tcp').rsplit(':', 1)[1]
    env = dict(os.environ, PGHOST='127.0.0.1', PGPORT=pgport, PGUSER='testuser',
               PGPASSWORD='testpass', PGDATABASE='platform_crud_test', PGSSLMODE='disable', FLUX_EVENT_LOOPS='2')
    with tempfile.TemporaryFile() as log:
        try:
            server, port = start(env, log, legacy=True)
            sql("INSERT INTO todos(title,done) VALUES ('preserved anonymous private content',true)")
            a, ta = account('owner_a')
            history = sql('SELECT row_to_json(m)::text FROM flux_db_meta.migrations m ORDER BY version')
            stop(server); server = None
            server, port = start(env, log)
            assert sql('SELECT count(*) FROM flux_db_meta.migrations') == '3'
            assert sql('SELECT row_to_json(m)::text FROM flux_db_meta.migrations m WHERE version<3 ORDER BY version') == history
            assert sql('SELECT title,done FROM todos_anonymous_archive') == 'preserved anonymous private content|t'
            assert call('todos/list', {'afterId':None}, ta) == {'nextId':None,'todos':[]}
            assert sql("SELECT to_regclass('todos') IS NULL") == 't'
            legacy = ROOT.parent / 'packages/auth/test/build/exec/flux-auth-integration-test_app'
            old = subprocess.run([str(legacy/'flux-auth-integration-test.so'),'--migrate-only'],timeout=30,
                env=dict(env,IDRIS2_INC_SRC=str(legacy),LD_LIBRARY_PATH=str(legacy),DYLD_LIBRARY_PATH=str(legacy)),stdout=log,stderr=log)
            assert old.returncode != 0, 'old binaries must reject future migration history'
            print('PASS populated v2 upgrade: exact v1/v2 history, account/session preserved; anonymous data archived, never adopted')
            b, tb = account('owner_b')
            methods = {'create':{'title':'anonymous'},'get':{'id':'1'},'list':{'afterId':None},
                       'update':{'id':'1','title':'forged','done':True},'toggle':{'id':'1'},'delete':{'id':'1'}}
            for method, data in methods.items():
                call('todos/'+method,data,expected=401)
                call('todos/'+method,data,'invalid-token',expected=401)
            aa = call('todos/create', {'title':'Only A','ownerId':b,'owner_id':b,'owner':b},ta)
            bb = call('todos/create', {'title':'Only B'},tb)
            assert sql('SELECT owner_id FROM private_todos WHERE id='+aa['id']) == a
            for method in ['get','toggle','update','delete']:
                data = {'id':aa['id'],'title':'stolen','done':True,'ownerId':a}
                assert call('todos/'+method,data,tb) == call('todos/'+method,dict(data,id='9223372036854775807'),tb)
            assert call('todos/get',{'id':aa['id']},ta)['todo'] == aa
            with ThreadPoolExecutor(max_workers=8) as workers:
                results = list(workers.map(lambda i: call('todos/toggle',{'id':aa['id']},ta if i%2==0 else tb),range(40)))
            assert all(r == {'todo':None} for r in results[1::2])
            assert call('todos/get',{'id':aa['id']},ta)['todo'] == aa
            sql("CREATE FUNCTION private_failure() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'PRIVATE_TASK_ERROR_SENTINEL %', NEW.title; END $$")
            sql('CREATE TRIGGER private_failure BEFORE UPDATE ON private_todos FOR EACH ROW EXECUTE FUNCTION private_failure()')
            failure = call('todos/update',{'id':aa['id'],'title':'PRIVATE_TASK_CONTENT_SENTINEL','done':True},ta,500)
            assert 'PRIVATE_TASK_' not in json.dumps(failure)
            log.flush(); log.seek(0)
            assert b'PRIVATE_TASK_' not in log.read(), 'PG exception detail must not leak into server logs'
            log.seek(0,2)
            sql('DROP TRIGGER private_failure ON private_todos'); sql('DROP FUNCTION private_failure()')
            assert call('todos/get',{'id':aa['id']},ta)['todo'] == aa
            print('PASS private content-bearing PG errors are absent from responses/logs; failed mutation is atomic')
            call('todos/delete',{'id':aa['id']},ta); call('todos/delete',{'id':bb['id']},tb)
            print('PASS every route protected, forged owner ignored, foreign IDs indistinguishable, concurrent atomic scoped mutations')
            generated, _ = account('generated_client')
            sql('ALTER SEQUENCE private_todos_id_seq RESTART WITH 9223372036854775000')
            sql(f"INSERT INTO private_todos(owner_id,title) SELECT {generated},'seed-' || n::text FROM generate_series(1,55) AS n")
            for target in ['node', 'browser']:
                subprocess.run(['node', str(ROOT / 'run_web_client.cjs'), f'http://127.0.0.1:{port}', 'crud', target], check=True, timeout=120)
                assert sql('SELECT count(*) FROM private_todos') == '55'
                assert sql("SELECT count(*) FROM private_todos WHERE title LIKE 'seed-%' AND done = false") == '55'
                print(f'PASS PG independently confirms intact private seeds after {target} CRUD')
            native = ROOT / 'crud/build/exec/platform-native-auth-test_app'
            subprocess.run([str(native/'platform-native-auth-test.so'),f'http://127.0.0.1:{port}'], check=True, timeout=90,
                           env=dict(os.environ, IDRIS2_INC_SRC=str(native), LD_LIBRARY_PATH=str(native), DYLD_LIBRARY_PATH=str(native)))
            sql(f"INSERT INTO private_todos(owner_id,title) SELECT CASE WHEN n%2=0 THEN {a} ELSE {b} END,'isolated-'||n::text FROM generate_series(1,102) AS n")
            for owner, token in [(a,ta),(b,tb)]:
                expected = sql(f'SELECT id FROM private_todos WHERE owner_id={owner} ORDER BY id').splitlines()
                first = call('todos/list',{'afterId':None},token)
                assert len(first['todos']) == 50 and first['nextId'] == expected[49]
                last = call('todos/list',{'afterId':first['nextId']},token)
                assert last['nextId'] is None and [t['id'] for t in first['todos']+last['todos']] == expected
                forged = sql(f'SELECT id FROM private_todos WHERE owner_id<>{owner} ORDER BY id DESC LIMIT 1')
                page = call('todos/list',{'afterId':forged,'ownerId':b if owner==a else a},token)
                assert all(t['id'] in expected and int(t['id'])>int(forged) for t in page['todos'])
            print('PASS interleaved two-owner 50/1 keyset pages and foreign-owner cursors never disclose other tasks')
            stop(server); server = None
            docker('restart',name); ready_db()
            assert docker('port',name,'5432/tcp').endswith(':'+pgport)
            server, port = start(env, log)
            assert sql('SELECT count(*) FROM private_todos') == '157'
            assert sql('SELECT count(*) FROM todos_anonymous_archive') == '1'
            assert len(call('todos/list',{'afterId':None},ta)['todos']) == 50
            call('auth/logoutall',token=ta)
            digest = hashlib.sha256(tb.encode()).hexdigest()
            sql(f"UPDATE flux_auth_sessions SET created_at=clock_timestamp()-interval '2 days',expires_at=clock_timestamp()-interval '1 day' WHERE digest='{digest}'")
            for method, data in methods.items():
                call('todos/'+method,data,ta,401); call('todos/'+method,data,tb,401)
            assert sql('SELECT count(*) FROM private_todos') == '157'
            assert sql('SELECT row_to_json(m)::text FROM flux_db_meta.migrations m WHERE version<3 ORDER BY version') == history
            print('PASS private data/session persistence across server + PostgreSQL restarts; expiry and revocation reject all task endpoints')
            stop(server); server = None
        except BaseException:
            log.seek(0); print(log.read().decode(errors='replace')); raise
finally:
    if server is not None and server.poll() is None: server.kill(); server.wait()
    if created: docker('rm', '-f', '-v', name)
