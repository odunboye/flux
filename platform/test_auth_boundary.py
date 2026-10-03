"""Real HTTP test of generated authentication boundaries, not durable sessions."""
import http.client
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parent
APP = ROOT / 'auth-boundary/build/exec/flux-auth-boundary-test_app'


def main():
    subprocess.run(['python3', str(ROOT/'generate.py'), str(ROOT/'auth-boundary/schema.json'),
                    '--out', str(ROOT/'auth-boundary'), '--check'], check=True, timeout=10)
    with socket.socket() as reserve:
        reserve.bind(('127.0.0.1', 0)); port = reserve.getsockname()[1]
    env = dict(os.environ, IDRIS2_INC_SRC=str(APP), LD_LIBRARY_PATH=str(APP),
               DYLD_LIBRARY_PATH=str(APP), FLUX_EVENT_LOOPS='2')
    with tempfile.TemporaryFile() as log:
        server = subprocess.Popen([str(APP/'flux-auth-boundary-test.so'), str(port), '128'],
                                  env=env, stdout=log, stderr=log)
        try:
            for _ in range(100):
                if server.poll() is not None: raise AssertionError('server exited at startup')
                try:
                    with socket.create_connection(('127.0.0.1', port), timeout=.1): break
                except OSError: time.sleep(.1)
            else: raise AssertionError('server startup timeout')

            def request(token=None, body='{"claimedOwner":"spoofed"}', path='private', content_type='application/json', duplicate=False, method='POST'):
                conn = http.client.HTTPConnection('127.0.0.1', port, timeout=3)
                try:
                    conn.putrequest(method, '/rpc/v1/probe/'+path)
                    conn.putheader('Content-Type', content_type)
                    conn.putheader('Content-Length', str(len(body.encode())))
                    if token is not None: conn.putheader('Authorization', token)
                    if duplicate: conn.putheader('aUtHoRiZaTiOn', 'Bearer fixture-b')
                    conn.endheaders(body.encode())
                    response = conn.getresponse()
                    return response.status, response.read(65537), dict(response.getheaders())
                finally: conn.close()

            for token in [None, '', 'Bearer missing', 'Basic fixture-a']:
                for body in ['{"claimedOwner":"user-a"}', '{']:
                    status, data, headers = request(token, body)
                    assert status == 401, (status, data)
                    assert json.loads(data)['error']['code'] == 'unauthenticated'
                    assert headers.get('Cache-Control') == 'no-store', headers
            print('PASS authentication precedes body parsing and cannot use a claimed owner')
            for who in ['a', 'b']:
                status, data, headers = request('Bearer fixture-'+who)
                assert status == 200 and json.loads(data) == {'resolvedOwner': 'user-'+who}
                assert headers.get('Cache-Control') == 'no-store'
            assert request('Bearer fixture-a', '{')[0] == 400
            assert request('Bearer fixture-a', content_type='text/plain')[0] == 415
            print('PASS generated callback receives server principal; normal validation still applies')
            status, data, headers = request('Bearer broken-store')
            assert status == 500 and b'secret' not in data and b'database' not in data
            assert headers.get('Cache-Control') == 'no-store'
            assert request('Bearer fixture-a', duplicate=True)[0] == 400
            assert request(path='public')[0] == 200
            assert request(method='OPTIONS', body='')[0] == 204
            print('PASS resolver errors redacted, duplicate Authorization rejected, mixed public/protected routes')
        except BaseException:
            log.seek(0); print(log.read().decode(errors='replace')); raise
        finally:
            server.terminate()
            try: code = server.wait(timeout=40)
            except subprocess.TimeoutExpired:
                server.kill(); server.wait(timeout=5); raise AssertionError('shutdown deadline')
        assert code == 0, code
    print('PASS authentication-boundary HTTP integration and clean shutdown')


if __name__ == '__main__': main()
