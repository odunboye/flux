#!/usr/bin/env python3
"""Bounded local-only diagnostic probes. Build security/security.ipkg first."""
import json
import os
from pathlib import Path
import re
import socket
import subprocess
import tempfile
import time
import socket_suite as suite

results = {"commit": "9394efe", "probes": []}


def probe(port, name, raw, **options):
    data, ended = suite.exchange(port, raw, **options)
    row = {"name": name, "statuses": re.findall(r"HTTP/1.1 (\d{3})", data.decode("latin1")),
           "response": data.decode("latin1"), "end": ended}
    results["probes"].append(row)
    print(name, row["statuses"], ended, flush=True)
    return row


get = b"GET / HTTP/1.1\r\nHost: localhost\r\n\r\n"
proc, port = suite.start("additional-example-probes", 1)
try:
    for header in [b"Content-Length : 5", b"Transfer-Encoding : chunked", b"Content-Length\t: 5"]:
        raw = b"POST /api/users HTTP/1.1\r\nHost: localhost\r\n" + header + b"\r\n\r\n" + get
        probe(port, "whitespace-" + header.decode(), raw)
    body = b'{"name":"TruncatedCanary","email":"local@example.test"}'
    raw = b"POST /api/users HTTP/1.1\r\nHost: localhost\r\nContent-Length: 999\r\n\r\n" + body
    probe(port, "truncated-valid-json", raw, half_close=True)
    probe(port, "verify-truncated-write", get.replace(b"GET / ", b"GET /api/users "))
finally:
    results["example_shutdown"] = suite.stop(proc)

fixture = Path(tempfile.mkdtemp(prefix="flux-resource-audit-"))
(fixture / "public").mkdir()
target = fixture / "public/control.txt"
target.write_text("RESOURCE_CONTROL\n")
appdir = suite.ROOT / "test/security/build/exec/flux-security-probes_app"
env = dict(os.environ, IDRIS2_INC_SRC=str(appdir), LD_LIBRARY_PATH=str(appdir),
           DYLD_LIBRARY_PATH=str(appdir), IDRIS2_ASYNC_THREADS="1",
           FLUX_SERVER_HOST="127.0.0.1", FLUX_SERVER_TIMEOUT="1500")
with socket.socket() as s:
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
env["FLUX_SERVER_PORT"] = str(port)
with open(fixture / "server.log", "wb") as log:
    proc = subprocess.Popen([str(appdir / "flux-security-probes.so")], cwd=fixture,
                            env=env, stdout=log, stderr=log)


def descriptors():
    output = subprocess.run(["lsof", "-nP", "-p", str(proc.pid)], capture_output=True, text=True).stdout
    return sum(str(target) in line for line in output.splitlines())


try:
    for _ in range(100):
        try:
            with socket.create_connection(("127.0.0.1", port), 0.1):
                break
        except OSError:
            if proc.poll() is not None:
                raise RuntimeError("probe server failed to start")
            time.sleep(0.05)
    results["fd_counts"] = {"baseline": descriptors()}
    for mode, method, suffix in [("normal_get", "GET", ""), ("head", "HEAD", ""),
                                  ("304", "GET", "?mode=304"), ("after_error", "GET", "?mode=error")]:
        for _ in range(12):
            raw = f"{method} /file/control.txt{suffix} HTTP/1.1\r\nHost: localhost\r\n\r\n".encode()
            suite.exchange(port, raw, timeout=0.05)
        results["fd_counts"][mode] = descriptors()
        print("open control-file descriptors after", mode, results["fd_counts"][mode], flush=True)
    time.sleep(4)
    results["fd_counts"]["after_idle_timeout"] = descriptors()
    probe(port, "always-control", get)
    probe(port, "always-failure", get.replace(b"GET / ", b"GET /?failAlways=1 "))
    injected = b"canary\r\nX-Injected: yes"
    probe(port, "header-injection", b"POST /echo-header HTTP/1.1\r\nHost: localhost\r\nContent-Length: " + str(len(injected)).encode() + b"\r\n\r\n" + injected)
    raw = b"POST /double-read HTTP/1.1\r\nHost: localhost\r\nContent-Length: 3\r\n\r\n"
    probe(port, "double-read-fragmented", raw, pieces=[raw, b"abc", get])
finally:
    results["probe_shutdown"] = suite.stop(proc)
results["fixture"] = str(fixture)
dest = Path(__file__).parent / "reports/2026-09-09-additional-security.json"
dest.write_text(json.dumps(results, indent=2))
print("Results:", dest, flush=True)
