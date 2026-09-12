"""Exercise the renamed native TUI entry point and C FFI in a real pseudo-terminal."""
import contextlib
import fcntl
import os
from pathlib import Path
import pty
import select
import signal
import struct
import subprocess
import termios
import time

ROOT = Path(__file__).resolve().parents[1]


def check(directory, name, banner):
    app = directory / f'build/exec/{name}_app'
    master, slave = pty.openpty()
    process = None
    output = b''
    try:
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 24, 100, 0, 0))
        env = dict(os.environ, IDRIS2_INC_SRC=str(app), LD_LIBRARY_PATH=str(app), DYLD_LIBRARY_PATH=str(app))
        env.pop('ANTHROPIC_API_KEY', None)
        process = subprocess.Popen([str(app / f'{name}.so')], cwd=directory, env=env,
                                   stdin=slave, stdout=slave, stderr=slave, start_new_session=True)
        os.close(slave)
        slave = None
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            if select.select([master], [], [], .1)[0]:
                try:
                    output = (output + os.read(master, 65536))[-65536:]
                except OSError:
                    break
                if banner in output:
                    break
            if process.poll() is not None:
                break
        assert banner in output, output.decode(errors='replace')
        os.write(master, b'q')
        # Keep draining: a renderer can otherwise block on the PTY's small
        # output buffer before it gets to consume the quit key.
        deadline = time.monotonic() + 10
        while process.poll() is None and time.monotonic() < deadline:
            if select.select([master], [], [], .1)[0]:
                try:
                    output = (output + os.read(master, 65536))[-65536:]
                except OSError:
                    break
        assert process.wait(timeout=max(.01, deadline - time.monotonic())) == 0, output.decode(errors='replace')
        print(f'PASS {name}: native TUI render, renamed C FFI and keyboard shutdown')
    finally:
        if process is not None and process.poll() is None:
            with contextlib.suppress(ProcessLookupError):
                os.killpg(process.pid, signal.SIGKILL)
            process.wait()
        os.close(master)
        if slave is not None:
            os.close(slave)


if __name__ == '__main__':
    check(ROOT, 'flux-ui-demo', b'flux-ui coding agent')
    check(ROOT / 'examples/todo', 'flux-ui-todo', b'Flux UI Todo')
