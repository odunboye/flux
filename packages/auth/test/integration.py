"""Owned PostgreSQL/TLS fixture for real durable accounts and revocation."""
from pathlib import Path
import concurrent.futures
import hashlib
import http.client
import json
import os
import re
import socket
import subprocess
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parents[3]
APP = ROOT/'packages/auth/test/build/exec/flux-auth-integration-test_app'
PASSWORD = 'correct horse λ battery!'
NEW_PASSWORD = 'changed horse λ battery!'


def run(args, **kwargs):
    return subprocess.run(args, check=True, timeout=40, capture_output=True, text=True, **kwargs)


def main():
    run(['python3',str(ROOT/'platform/generate.py'),str(ROOT/'platform/auth-boundary/schema.json'),
         '--out',str(ROOT/'packages/auth/test'),'--check'])
    name = 'flux-accounts-' + uuid.uuid4().hex[:12]
    created = False
    server = None
    tokens = []
    with tempfile.TemporaryDirectory(prefix='flux-accounts-', dir='/tmp') as temp, tempfile.TemporaryFile() as log:
        d = Path(temp)
        run(['openssl','req','-x509','-newkey','ec','-pkeyopt','ec_paramgen_curve:P-256','-nodes',
             '-keyout',str(d/'key.pem'),'-out',str(d/'cert.pem'),'-days','1','-subj','/CN=localhost',
             '-addext','subjectAltName=DNS:localhost,IP:127.0.0.1'])
        command = '''set -eu
mkdir -p /tmp/tls
cp /input/key.pem /input/cert.pem /tmp/tls/
chown -R postgres:postgres /tmp/tls
chmod 600 /tmp/tls/key.pem
exec docker-entrypoint.sh postgres -c ssl=on -c ssl_cert_file=/tmp/tls/cert.pem -c ssl_key_file=/tmp/tls/key.pem
'''
        try:
            with socket.socket() as reserve:
                reserve.bind(('127.0.0.1',0)); pg_port = reserve.getsockname()[1]
            run(['docker','run','--pull','never','--rm','-d','--name',name,'-p',f'127.0.0.1:{pg_port}:5432',
                 '-e','POSTGRES_USER=testuser','-e','POSTGRES_PASSWORD=testpass','-e','POSTGRES_DB=testdb',
                 '-v',str(d)+':/input:ro','--entrypoint','sh','postgres:16','-c',command])
            created = True
            def ready_db():
                for _ in range(100):
                    try: run(['docker','exec',name,'pg_isready','-h','127.0.0.1','-U','testuser','-d','testdb']); return
                    except subprocess.CalledProcessError: time.sleep(.2)
                raise AssertionError('database startup deadline')
            ready_db()
            port = run(['docker','port',name,'5432/tcp']).stdout.strip().rsplit(':',1)[1]
            env = dict(os.environ, PGHOST='127.0.0.1', PGPORT=port, PGUSER='testuser',
                       PGPASSWORD='testpass', PGDATABASE='testdb', PGSSLMODE='verify-full',
                       PGSSLROOTCERT=str(d/'cert.pem'), IDRIS2_INC_SRC=str(APP),
                       LD_LIBRARY_PATH=str(APP), DYLD_LIBRARY_PATH=str(APP),
                       FLUX_EVENT_LOOPS='2', AUTH_SESSION_TTL_SECONDS='3600')
            def sql(statement):
                return run(['docker','exec',name,'psql','-U','testuser','-d','testdb','-v','ON_ERROR_STOP=1','-Atc',statement]).stdout.strip()
            binary = str(APP/'flux-auth-integration-test.so')
            # Real reviewed v1 migration history, before introducing accounts.
            run([binary, '--legacy-only'], env=env)
            sql("INSERT INTO todos(title) VALUES ('preserve anonymous task')")
            history = sql('SELECT row_to_json(m)::text FROM flux_db_meta.migrations m ORDER BY version')
            with socket.socket() as reserve:
                reserve.bind(('127.0.0.1',0)); web_port = reserve.getsockname()[1]
            def start(ttl=3600):
                nonlocal server
                server = subprocess.Popen([binary,str(web_port),'128'], env=dict(env, AUTH_SESSION_TTL_SECONDS=str(ttl)), stdout=log, stderr=log)
                for _ in range(100):
                    if server.poll() is not None: raise AssertionError('server exited at startup')
                    try:
                        with socket.create_connection(('127.0.0.1',web_port),timeout=.1): return
                    except OSError: time.sleep(.1)
                raise AssertionError('server startup deadline')
            def stop():
                nonlocal server
                if server is None: return
                server.terminate()
                try: code = server.wait(timeout=40)
                except subprocess.TimeoutExpired:
                    server.kill(); server.wait(timeout=5); raise AssertionError('joined shutdown deadline')
                server = None
                assert code == 0, code
            def call(path, payload=None, token=None, headers=None):
                conn = http.client.HTTPConnection('127.0.0.1',web_port,timeout=8)
                try:
                    hs = {'Content-Type':'application/json'}
                    if token: hs['Authorization'] = 'Bearer '+token
                    if headers: hs.update(headers)
                    conn.request('POST','/rpc/v1/'+path,json.dumps(payload or {}),hs)
                    response = conn.getresponse(); data = response.read(65537)
                    assert len(data) <= 65536
                    assert response.getheader('Cache-Control') == 'no-store' or path == 'probe/public'
                    return response.status, json.loads(data)
                finally: conn.close()
            def register(user, password=PASSWORD):
                status, data = call('auth/register',dict(username=user,password=password))
                assert status == 200, (status, data)
                assert set(data) == {'id','username'}
                return data
            def login(user, password=PASSWORD):
                status, data = call('auth/login',dict(username=user,password=password))
                assert status == 200, (status, data)
                token = data['token']; assert re.fullmatch('[A-Za-z0-9_-]{43}',token)
                assert token not in tokens; tokens.append(token)
                return token
            def me(token, status=200):
                code, data = call('auth/me',token=token)
                assert code == status, (code,data)
                return data
            start()
            assert sql('SELECT row_to_json(m)::text FROM flux_db_meta.migrations m WHERE version=1') == history
            assert sql('SELECT count(*) FROM flux_db_meta.migrations') == '2'
            assert sql('SELECT title FROM todos') == 'preserve anonymous task'
            print('PASS additive migration preserves anonymous data and full v1 history')
            a = register('Account_A'); b = register('account_b')
            assert a['username'] == 'account_a' and a['id'] != b['id']
            assert call('auth/register',dict(username='ACCOUNT_A',password=PASSWORD))[0] == 409
            for pw in ['short', 'x'*257, 'a'*12+'\0']:
                assert call('auth/register',dict(username='invalid_user',password=pw))[0] == 400
            assert call('auth/register',dict(username='bad name',password=PASSWORD))[0] == 400
            unknown = call('auth/login',dict(username='unknown_user',password=PASSWORD))
            wrong = call('auth/login',dict(username='account_a',password='wrong password!'))
            assert unknown == wrong and wrong[0] == 401
            ta = login('ACCOUNT_A'); tb = login('account_b'); tb2 = login('account_b')
            assert me(ta) == a and me(tb) == b
            assert call('auth/me',[1],ta)[0] == 400
            oversized = call('auth/me',dict(ignored='x'*65536),ta)
            assert oversized[0] == 400 and oversized[1]['error']['message'] == 'could not read request body'
            assert call('auth/logout',token=ta,headers={'Content-Type':'text/plain'})[0] == 415
            me(ta)
            assert call('probe/private',dict(claimedOwner=b['id']),ta) == (200, {'resolvedOwner':a['id']})
            assert call('probe/private',dict(token=ta,claimedOwner=a['id']))[0] == 401
            assert call('auth/me',headers={'Cookie':'session='+ta})[0] == 401
            assert call('auth/me',headers={'Authorization':'Bearer '+ta+', '+tb})[0] == 401
            hashes = sql('SELECT password_hash FROM flux_auth_accounts ORDER BY id').splitlines()
            assert len(set(hashes)) == 2 and all(h.startswith('$argon2id$v=19$m=65536,t=3,p=1$') for h in hashes)
            stored = sql('SELECT digest FROM flux_auth_sessions').splitlines()
            assert hashlib.sha256(ta.encode()).hexdigest() in stored and all(re.fullmatch('[0-9a-f]{64}',x) for x in stored)
            assert ta not in '\n'.join(stored) and PASSWORD not in '\n'.join(hashes)
            print('PASS salted Argon2id, opaque digest-only sessions, real protected resolver and generic failures')
            browser = run(['node', str(ROOT/'packages/auth/test/browser.cjs'), f'http://127.0.0.1:{web_port}'])
            print(browser.stdout, end='')
            stop(); start(); assert me(ta) == a
            run(['docker','restart',name]); ready_db()
            assert run(['docker','port',name,'5432/tcp']).stdout.strip().endswith(':'+port)
            for _ in range(20):
                code, data = call('auth/me',token=ta)
                if code == 200: break
                assert code in (500,503); time.sleep(.1)
            else: raise AssertionError('pool failed to recover after DB restart')
            assert data == a
            print('PASS account and session persistence across server and PostgreSQL restarts')
            expired = login('account_a')
            digest = hashlib.sha256(expired.encode()).hexdigest()
            sql(f"UPDATE flux_auth_sessions SET created_at=clock_timestamp()-interval '2 hours',expires_at=clock_timestamp()-interval '1 hour' WHERE digest='{digest}'")
            me(expired,401); me(ta)
            assert call('auth/logout',dict(accountId=a['id'],token=ta),tb)[0] == 200
            me(tb,401); me(tb2); me(ta)
            assert call('auth/logoutall',token=ta)[0] == 200
            me(ta,401); me(tb2)
            stop(); start(); me(ta,401); me(tb,401)
            ta = login('account_a')
            tb3 = login('account_b')
            assert call('auth/password',dict(currentPassword='wrong password!',newPassword=NEW_PASSWORD),tb2)[0] == 401
            me(tb2)
            assert call('auth/password',dict(currentPassword=PASSWORD,newPassword=NEW_PASSWORD),tb2)[0] == 200
            me(tb2,401); me(tb3,401)
            assert call('auth/login',dict(username='account_b',password=PASSWORD))[0] == 401
            tb = login('account_b',NEW_PASSWORD); me(tb)
            print('PASS expiry, current/all-session logout, scoped revocation and atomic password-change revocation')
            register('locked_account')
            for _ in range(10): assert call('auth/login',dict(username='locked_account',password='wrong password!'))[0] == 401
            assert call('auth/login',dict(username='locked_account',password=PASSWORD))[0] == 401
            stop(); start()
            assert call('auth/login',dict(username='locked_account',password=PASSWORD))[0] == 401
            sql("UPDATE flux_auth_accounts SET attempt_window=clock_timestamp()-interval '61 seconds' WHERE username='locked_account'")
            me(login('locked_account'))
            cap = register('session_cap')
            sql(f"INSERT INTO flux_auth_sessions(digest,account_id,expires_at) SELECT md5('cap'||i::text)||md5('cap'||i::text),{cap['id']},clock_timestamp()+interval '1 hour' FROM generate_series(1,32) i")
            assert call('auth/login',dict(username='session_cap',password=PASSWORD))[0] == 401
            assert sql(f"SELECT count(*) FROM flux_auth_sessions WHERE account_id={cap['id']}") == '32'
            sql(f"DELETE FROM flux_auth_sessions WHERE digest=(SELECT digest FROM flux_auth_sessions WHERE account_id={cap['id']} LIMIT 1)")
            with concurrent.futures.ThreadPoolExecutor(max_workers=2) as workers:
                results = list(workers.map(lambda _: call('auth/login',dict(username='session_cap',password=PASSWORD)), range(2)))
            assert sorted(status for status,_ in results) == [200,401]
            for status, data in results:
                if status == 200: tokens.append(data['token']); me(data['token'])
            assert sql(f"SELECT count(*) FROM flux_auth_sessions WHERE account_id={cap['id']}") == '32'
            with concurrent.futures.ThreadPoolExecutor(max_workers=2) as workers:
                duplicates = list(workers.map(lambda _: call('auth/register',dict(username='registration_race',password=PASSWORD))[0], range(2)))
            assert sorted(duplicates) == [200,409], duplicates
            print('PASS durable attempt window, concurrent session cap and unique-registration race')
            # Independent concurrent hashing requests cannot monopolize the owner loop.
            def concurrent_register(i): return call('auth/register',dict(username=f'parallel_{i}',password=PASSWORD))[0]
            with concurrent.futures.ThreadPoolExecutor(max_workers=8) as workers:
                pending = [workers.submit(concurrent_register,i) for i in range(8)]
                before = time.monotonic()
                assert call('probe/public',dict(claimedOwner='irrelevant'))[0] == 200
                assert time.monotonic()-before < 2
                statuses = [p.result(timeout=8) for p in pending]
            assert set(statuses) <= {200,429} and 429 in statuses and 200 in statuses, statuses
            print('PASS bounded hashing admission and responsive owner loop under contention')
            stop(); start(ttl=1)
            short = login('account_a'); time.sleep(1.1); me(short,401); me(ta)
            print('PASS actual database-clock short session expiry without extending test deadlines')
            stop(); start()
            for i in range(3):
                user = f'password_race_{i}'
                register(user); current = login(user)
                with concurrent.futures.ThreadPoolExecutor(max_workers=2) as workers:
                    pending = workers.submit(call, 'auth/login', dict(username=user,password=PASSWORD))
                    changed = workers.submit(call, 'auth/password', dict(currentPassword=PASSWORD,newPassword=NEW_PASSWORD), current)
                    assert changed.result(timeout=8)[0] == 200
                    status, session = pending.result(timeout=8)
                assert status in (200,401), status
                if status == 200:
                    tokens.append(session['token']); me(session['token'],401)
                me(current,401); me(login(user,NEW_PASSWORD))
            print('PASS concurrent old-password login cannot survive password-change revocation')
            # Corrupt work factors must fail closed without allocating attacker-sized Argon memory.
            corrupt = register('corrupt_hash')
            sql(f"UPDATE flux_auth_accounts SET password_hash='$argon2id$v=19$m=999999999,t=99,p=1$invalid' WHERE id={corrupt['id']}")
            before = time.monotonic()
            status, data = call('auth/login',dict(username='corrupt_hash',password=PASSWORD))
            assert status == 500 and time.monotonic()-before < 2
            assert '999999' not in json.dumps(data)
            sql("CREATE FUNCTION reject_auth_canary() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF NEW.username='storage_canary' THEN RAISE EXCEPTION 'database_auth_secret_canary:%', NEW.password_hash; END IF; RETURN NEW; END $$")
            sql('CREATE TRIGGER auth_canary BEFORE INSERT ON flux_auth_accounts FOR EACH ROW EXECUTE FUNCTION reject_auth_canary()')
            status, data = call('auth/register',dict(username='storage_canary',password=PASSWORD))
            assert status == 500 and 'canary' not in json.dumps(data)
            sql('DROP TRIGGER auth_canary ON flux_auth_accounts')
            sql('ALTER TABLE flux_auth_sessions RENAME TO unavailable_sessions')
            assert call('probe/private',token=ta)[0] == 500
            sql('ALTER TABLE unavailable_sessions RENAME TO flux_auth_sessions')
            me(ta)
            stop()
            log.seek(0); output = log.read().decode(errors='replace')
            for secret in [PASSWORD, NEW_PASSWORD, 'database_auth_secret_canary', '$argon2id$', *tokens, *hashes]: assert secret not in output, 'credential leaked into logs'
            print('PASS corrupt hash costs bounded, store outage fails closed, credentials absent from server logs')
        finally:
            if server is not None:
                server.terminate()
                try: server.wait(timeout=40)
                except subprocess.TimeoutExpired: server.kill(); server.wait(timeout=5); raise
            if created: run(['docker','rm','-f','-v',name])
    print('PASS durable account/session PostgreSQL TLS integration')


if __name__ == '__main__': main()
