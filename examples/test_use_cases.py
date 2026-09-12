"""Real HTTP checks for the focused, stateless examples; no database required."""
import http.client
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parent


def main():
    binary = ROOT / 'build/exec/flux-use-cases_app/flux-use-cases.so'
    with socket.socket() as reserve:
        reserve.bind(('127.0.0.1', 0))
        port = reserve.getsockname()[1]
    env = dict(os.environ, FLUX_SERVER_HOST='127.0.0.1', FLUX_SERVER_PORT=str(port),
               IDRIS2_INC_SRC=str(binary.parent), LD_LIBRARY_PATH=str(binary.parent),
               DYLD_LIBRARY_PATH=str(binary.parent))
    with tempfile.TemporaryFile() as log:
        process = subprocess.Popen([str(binary)], cwd=ROOT, env=env, stdout=log, stderr=log)
        try:
            for _ in range(100):
                if process.poll() is not None:
                    raise AssertionError('example exited during startup')
                try:
                    with socket.create_connection(('127.0.0.1', port), timeout=.1):
                        break
                except OSError:
                    time.sleep(.05)
            else:
                raise AssertionError('example startup deadline')

            def request(method, path, body=None, content_type='application/json', status=200):
                connection = http.client.HTTPConnection('127.0.0.1', port, timeout=5)
                try:
                    connection.request(method, path, body, {'Content-Type': content_type})
                    response = connection.getresponse()
                    value = json.loads(response.read())
                    assert response.status == status, (path, response.status, value)
                    assert response.getheader('X-Request-ID')
                    assert response.getheader('X-Content-Type-Options') == 'nosniff'
                    return value
                finally:
                    connection.close()

            assert request('GET', '/hello/Ada') == {'message': 'Hello, Ada!'}
            assert request('GET', '/hello/Ada?language=es') == {'message': 'Hola, Ada!'}
            request('GET', '/hello/Ada?language=unknown', status=400)
            assert request('POST', '/quotes', '{"quantity":3,"unitPriceCents":1250}') == {'quantity':3,'totalCents':3750}
            assert request('POST', '/quotes', '{"quantity":1000,"unitPriceCents":1000000}')['totalCents'] == 1000000000
            for body in ['{}', '{', '{"quantity":"3","unitPriceCents":1}',
                         '{"quantity":0,"unitPriceCents":1}', '{"quantity":1,"unitPriceCents":-1}',
                         '{"quantity":1001,"unitPriceCents":1}', 'x'*2049]:
                request('POST', '/quotes', body, status=400)
            request('POST', '/quotes', '{}', content_type='text/plain', status=415)
            for path in ['/health', '/ready', '/live', '/startup']:
                request('GET', path)
            print('PASS greetings, typed quotes, domain/body limits, error middleware and health routes')
        except BaseException:
            log.seek(0)
            print(log.read().decode(errors='replace'))
            raise
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=40)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
                    raise AssertionError('example shutdown deadline')
        assert process.returncode == 0
        print('PASS owned server shutdown')


if __name__ == '__main__':
    main()
