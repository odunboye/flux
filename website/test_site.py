"""Run the real Flux landing server and browser acceptance; no database required."""
import os
from pathlib import Path
import signal
import socket
import subprocess
import tempfile
import time
import urllib.request

ROOT = Path(__file__).resolve().parent
APP = ROOT / 'build/exec/flux-landing_app'


def main():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        port = sock.getsockname()[1]
    env = dict(os.environ, IDRIS2_INC_SRC=str(APP), LD_LIBRARY_PATH=str(APP), DYLD_LIBRARY_PATH=str(APP))
    with tempfile.TemporaryFile() as log:
        server = subprocess.Popen([str(APP / 'flux-landing.so'), str(port), '128'],
                                  cwd=ROOT, env=env, stdout=log, stderr=log, start_new_session=True)
        try:
            for _ in range(150):
                if server.poll() is not None:
                    raise RuntimeError('Landing server exited during startup')
                try:
                    with urllib.request.urlopen(f'http://127.0.0.1:{port}/health', timeout=.2) as response:
                        assert response.read() == b'ok\n'
                        break
                except OSError:
                    time.sleep(.1)
            else:
                raise RuntimeError('Landing server readiness timed out')
            subprocess.run(['node', str(ROOT / 'test_site.cjs'), f'http://127.0.0.1:{port}'],
                           check=True, timeout=120)
        except BaseException:
            log.seek(0)
            print(log.read().decode(errors='replace'))
            raise
        finally:
            if server.poll() is None:
                server.terminate()
            try:
                code = server.wait(timeout=40)
            except subprocess.TimeoutExpired:
                os.killpg(server.pid, signal.SIGKILL)
                server.wait()
                raise AssertionError('Landing server shutdown timed out')
            assert code == 0, code
            print('PASS Flux landing server clean shutdown')


if __name__ == '__main__':
    def interrupt(signum, frame):
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        signal.signal(signal.SIGINT, signal.SIG_IGN)
        raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, interrupt)
    signal.signal(signal.SIGINT, interrupt)
    main()
