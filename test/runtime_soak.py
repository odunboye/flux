"""Bounded HTTP soak, rotating through 1/2/4 fixed owner loops."""
import argparse
import concurrent.futures
import http.client
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[1]


def scenario(owners, seconds, directory):
    with socket.socket() as reserve:
        reserve.bind(('127.0.0.1', 0))
        port = reserve.getsockname()[1]
    app = ROOT / 'examples/build/exec/flux-examples_app'
    env = dict(os.environ, FLUX_EVENT_LOOPS=str(owners), FLUX_SERVER_PORT=str(port),
               FLUX_SERVER_HOST='127.0.0.1', FLUX_SERVER_WORKERS='128',
               FLUX_SERVER_TIMEOUT='5000', IDRIS2_INC_SRC=str(app),
               LD_LIBRARY_PATH=str(app), DYLD_LIBRARY_PATH=str(app))
    stopping = threading.Event()
    count = [0]
    lock = threading.Lock()
    result = {'owners': owners, 'seconds': seconds, 'samples': [], 'errors': []}
    output = directory / f'owners-{owners}.json'
    with (directory / f'owners-{owners}.log').open('wb') as log:
        server = subprocess.Popen([str(app / 'flux-examples.so'), '--from-env'],
                                  cwd=ROOT / 'examples', env=env, stdout=log, stderr=log)
    def client():
        conn = None
        cookie = None
        try:
            while not stopping.is_set():
                if conn is None:
                    conn = http.client.HTTPConnection('127.0.0.1', port, timeout=5)
                headers = {'Cookie': cookie} if cookie else {}
                conn.request('GET', '/', headers=headers)
                response = conn.getresponse()
                body = response.read()
                if response.status != 200 or body != b'Welcome to Flux!\n':
                    raise AssertionError((response.status, body[:100]))
                if response.getheader('Set-Cookie'):
                    cookie = response.getheader('Set-Cookie').split(';', 1)[0]
                with lock:
                    count[0] += 1
        finally:
            if conn:
                conn.close()
    try:
        for _ in range(100):
            if server.poll() is not None:
                raise RuntimeError('server exited during startup')
            try:
                with socket.create_connection(('127.0.0.1', port), timeout=.1):
                    break
            except OSError:
                time.sleep(.1)
        else:
            raise RuntimeError('server startup timed out')
        start = time.monotonic()
        with concurrent.futures.ThreadPoolExecutor(max_workers=24) as executor:
            jobs = [executor.submit(client) for _ in range(24)]
            try:
                while time.monotonic() - start < seconds:
                    time.sleep(min(30, max(.1, seconds - (time.monotonic() - start))))
                    for job in jobs:
                        if job.done():
                            job.result()
                            raise RuntimeError('client stopped unexpectedly')
                    if server.poll() is not None:
                        raise RuntimeError('server exited under load')
                    rss = int(subprocess.check_output(['ps', '-o', 'rss=', '-p', str(server.pid)], text=True).strip())
                    sample = {'elapsed': round(time.monotonic() - start, 2), 'requests': count[0], 'rss_kb': rss}
                    result['samples'].append(sample)
                    output.write_text(json.dumps(result, indent=2))
                    print(f'owners={owners} {sample}', flush=True)
            finally:
                stopping.set()
            for job in jobs:
                job.result()
        result['requests'] = count[0]
        if len(result['samples']) > 2:
            assert result['samples'][-1]['rss_kb'] < result['samples'][0]['rss_kb'] + 131072, 'RSS grew by over 128 MiB'
    except BaseException as error:
        result['errors'].append(str(error))
        raise
    finally:
        stopping.set()
        server.terminate()
        try:
            result['exit_code'] = server.wait(timeout=40)
        except subprocess.TimeoutExpired:
            server.kill()
            server.wait()
            result['errors'].append('shutdown exceeded independent watchdog deadline')
        output.write_text(json.dumps(result, indent=2))
    assert result['exit_code'] == 0, result
    print(f'PASS owners={owners}: {count[0]} requests, clean shutdown', flush=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--seconds', type=int, default=7200, help='total duration across 1/2/4 owners')
    args = parser.parse_args()
    directory = Path(tempfile.mkdtemp(prefix='flux-runtime-soak-'))
    print('Results:', directory, flush=True)
    for owners in (1, 2, 4):
        scenario(owners, max(1, args.seconds // 3), directory)


if __name__ == '__main__':
    main()
