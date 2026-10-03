"""Exercise real sockets under an external deadline; no fixed port or DB."""
import concurrent.futures
import pathlib
import os
import socket
import subprocess

ROOT = pathlib.Path(__file__).resolve().parent.parent


def main():
    app = ROOT / 'test/build/exec/flux-runtime-socket-test_app'
    env = dict(os.environ, IDRIS2_INC_SRC=str(app),
               LD_LIBRARY_PATH=str(app), DYLD_LIBRARY_PATH=str(app))
    server = subprocess.Popen(
        [str(app / 'flux-runtime-socket-test.so')], env=env,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
    )
    try:
        with concurrent.futures.ThreadPoolExecutor(max_workers=1) as executor:
            line = executor.submit(server.stdout.readline)
            try:
                port = int(line.result(timeout=10).strip())
            except Exception:
                server.kill()
                raise
        for data in (b"", b"hello\x00world\xff", bytes(range(256)) * 512, b"x" * 1000000):
            with socket.create_connection(("127.0.0.1", port), timeout=10) as client:
                client.settimeout(10)
                # Read concurrently so both directions exercise backpressure.
                with concurrent.futures.ThreadPoolExecutor(max_workers=1) as executor:
                    def collect():
                        chunks = []
                        while True:
                            chunk = client.recv(8192)
                            if not chunk:
                                return b"".join(chunks)
                            chunks.append(chunk)
                    result = executor.submit(collect)
                    client.sendall(data)
                    client.shutdown(socket.SHUT_WR)
                    assert result.result(timeout=10) == data
        out, err = server.communicate(timeout=10)
        assert server.returncode == 0, (server.returncode, out, err)
        print(out.strip())
        print("PASS byte-exact binary transfer and large payload backpressure")
    finally:
        if server.poll() is None:
            server.kill()
            server.wait(timeout=5)


if __name__ == "__main__":
    main()
