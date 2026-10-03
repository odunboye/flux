"""Run generated Idris/Flux UI native, JS and browser clients against Flux."""
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parent
app = ROOT / 'example/build/exec/platform-example_app'
with socket.socket() as reserve:
    reserve.bind(('127.0.0.1', 0))
    port = reserve.getsockname()[1]
env = dict(os.environ, IDRIS2_INC_SRC=str(app), LD_LIBRARY_PATH=str(app),
           DYLD_LIBRARY_PATH=str(app), FLUX_EVENT_LOOPS='2')
with tempfile.TemporaryFile() as log:
    server = subprocess.Popen([str(app / 'platform-example.so'), str(port), '128'],
                              env=env, cwd=ROOT, stdout=log, stderr=log)
    try:
        for _ in range(100):
            if server.poll() is not None:
                raise RuntimeError('server exited at startup')
            try:
                with socket.create_connection(('127.0.0.1', port), timeout=.1):
                    break
            except OSError:
                time.sleep(.1)
        else:
            raise RuntimeError('server startup timed out')
        base = f'http://127.0.0.1:{port}'
        native = ROOT / 'example/build/exec/platform-client-native-test_app'
        native_env = dict(os.environ, IDRIS2_INC_SRC=str(native), LD_LIBRARY_PATH=str(native),
                          DYLD_LIBRARY_PATH=str(native))
        result = subprocess.run([str(native / 'platform-client-native-test.so'), base],
                                env=native_env, check=True, timeout=90, text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        print(result.stdout, end='')
        assert 'PASS native Flux UI client checks complete' in result.stdout
        assert not any(line.startswith('FAIL ') for line in result.stdout.splitlines())
        for target in ['node', 'browser']:
            subprocess.run(['node', str(ROOT / 'run_web_client.cjs'), base, 'smoke', target],
                           check=True, timeout=90)
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
    print('PASS generated endpoint server clean shutdown')
