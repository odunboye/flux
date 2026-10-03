#!/usr/bin/env python3
"""Bounded localhost protocol probes and wrk load runs; no external targets.

Build examples/examples.ipkg first, then run: python3 test/socket_suite.py
Results, raw responses, server logs and resource samples go in a temporary directory.
"""
import json
import os
import platform
from pathlib import Path
import re
import shutil
import socket
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
OUT = Path(tempfile.mkdtemp(prefix="flux-socket-suite-"))
RESULTS = {"output": str(OUT), "platform": platform.platform(),
           "started_at": time.time(), "probes": [], "load": []}


def save():
    (OUT / "results.json").write_text(json.dumps(RESULTS, indent=2))


def exchange(port, payload, timeout=0.4, pieces=None, half_close=False):
    data = b""
    ended = "timeout"
    with socket.create_connection(("127.0.0.1", port), 2) as conn:
        conn.settimeout(timeout)
        for piece in pieces or [payload]:
            conn.sendall(piece)
            if pieces:
                time.sleep(0.01)
        if half_close:
            conn.shutdown(socket.SHUT_WR)
        try:
            while len(data) < 200000:
                part = conn.recv(65536)
                if not part:
                    ended = "eof"
                    break
                data += part
        except socket.timeout:
            pass
        except ConnectionResetError:
            ended = "reset"
    return data, ended


def start(label, threads, timeout=5000, cwd=None):
    with socket.socket() as reserve:
        reserve.bind(("127.0.0.1", 0))
        port = reserve.getsockname()[1]
    env = dict(os.environ, FLUX_EVENT_LOOPS=str(threads),
               FLUX_SERVER_PORT=str(port), FLUX_SERVER_HOST="127.0.0.1",
               FLUX_SERVER_WORKERS="128", FLUX_SERVER_TIMEOUT=str(timeout))
    appdir = ROOT / "examples/build/exec/flux-examples_app"
    env["IDRIS2_INC_SRC"] = str(appdir)
    for key in ["LD_LIBRARY_PATH", "DYLD_LIBRARY_PATH"]:
        env[key] = str(appdir) + (":" + env[key] if env.get(key) else "")
    log = open(OUT / (label + ".server.log"), "wb")
    proc = subprocess.Popen([str(appdir / "flux-examples.so"), "--from-env"],
                            cwd=cwd or ROOT / "examples", env=env, stdout=log, stderr=log)
    log.close()
    for _ in range(100):
        if proc.poll() is not None:
            raise RuntimeError(f"server exited: {label}")
        try:
            with socket.create_connection(("127.0.0.1", port), 0.1):
                return proc, port
        except OSError:
            time.sleep(0.1)
    proc.kill()
    proc.wait()
    raise RuntimeError("startup timeout")


def stop(proc):
    proc.terminate()
    try:
        proc.wait(timeout=12)
        return {"exit_code": proc.returncode, "forced": False}
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait()
        return {"exit_code": proc.returncode, "forced": True}


def sample(proc, phase):
    ps = subprocess.run(["ps", "-o", "rss=,%cpu=", "-p", str(proc.pid)],
                        capture_output=True, text=True).stdout.strip().split()
    fds = subprocess.run(["lsof", "-nP", "-a", "-p", str(proc.pid)],
                         capture_output=True, text=True).stdout.splitlines()
    return {"time": time.time(), "phase": phase, "rss_kib": int(ps[0]) if ps else None,
            "cpu_percent": float(ps[1]) if ps else None,
            "fd_rows": len(fds), "tcp_rows": sum("TCP" in x for x in fds),
            "close_wait": sum("CLOSE_WAIT" in x for x in fds)}


def adversarial():
    proc, port = start("protocol", 2, 1500)
    get = b"GET / HTTP/1.1\r\nHost: localhost\r\n\r\n"
    cases = [
        ("baseline", get, [200], {}),
        ("pipeline", get + get, [200, 200], {}),
        ("fragmented", get, [200], {"pieces": [get[i:i+3] for i in range(0, len(get), 3)]}),
        ("head_no_body", get.replace(b"GET", b"HEAD", 1), [200], {}),
        ("connection_close", get.replace(b"Host:", b"Connection: close\r\nHost:"), [200], {}),
        ("missing_host", b"GET / HTTP/1.1\r\n\r\n", [400], {}),
        ("invalid_length", b"POST /api/users HTTP/1.1\r\nHost: localhost\r\nContent-Length: nonsense\r\n\r\n" + get, [400], {}),
        ("conflicting_lengths", b"POST /api/users HTTP/1.1\r\nHost: localhost\r\nContent-Length: 5\r\nContent-Length: 0\r\n\r\n" + get, [400], {}),
        ("te_cl_conflict", b"POST /api/users HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\nContent-Length: 0\r\n\r\n" + get, [400], {}),
        ("chunked_request", b"POST /api/users HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\n\r\n2\r\n{}\r\n0\r\n\r\n" + get, None, {}),
        ("oversized_headers", b"GET / HTTP/1.1\r\nHost: localhost\r\nX-Pad: " + b"x"*66000 + b"\r\n\r\n", [400], {}),
        ("oversized_declared_body", b"POST /api/users HTTP/1.1\r\nHost: localhost\r\nContent-Length: 1048577\r\n\r\n", [400], {}),
        ("handler_body_limit", b"POST /api/users HTTP/1.1\r\nHost: localhost\r\nContent-Length: 4097\r\n\r\n" + b"x"*4097 + get, [413], {}),
        ("invalid_json_pipeline", b"POST /api/users HTTP/1.1\r\nHost: localhost\r\nContent-Length: 2\r\n\r\n{}" + get, [400, 200], {}),
        ("truncated_body", b"POST /api/users HTTP/1.1\r\nHost: localhost\r\nContent-Length: 100\r\n\r\n{}", [400], {"half_close": True}),
        ("partial_header_timeout", b"GET / HTTP/1.1\r\nHost:", [], {"timeout": 4}),
        ("error_headers", get.replace(b"GET / ", b"GET /api/users/999 "), [404], {}),
        ("static_stream", get.replace(b"GET / ", b"GET /static/hello.txt "), [200], {}),
    ]
    try:
        for name, raw, expected, options in cases:
            data, ended = exchange(port, raw, **options)
            statuses = [int(n) for n in re.findall(rb"HTTP/1\.1 (\d{3})", data)]
            result = {"name": name, "statuses": statuses, "expected_statuses": expected,
                      "end": ended, "status_check": statuses == expected if expected is not None else None,
                      "response": data.decode("latin1")}
            if name == "head_no_body":
                result["body_present"] = bool(data.partition(b"\r\n\r\n")[2])
            RESULTS["probes"].append(result)
            save()
            print(name, statuses, ended, flush=True)
    finally:
        RESULTS["protocol_shutdown"] = stop(proc)
        save()


def load():
    wrk = shutil.which("wrk")
    if not wrk:
        raise RuntimeError("wrk is required")
    # Reuse one established session across the generator to avoid creating a
    # new stored session on every request (wrk does not manage cookies).
    for threads, duration in [(1, 30), (2, 60), (4, 30)]:
        label = f"load-{threads}-threads"
        proc, port = start(label, threads)
        result = {"async_threads": threads, "duration_s": duration, "connections": 100,
                  "idle_timeout_ms": 5000, "samples": []}
        RESULTS["load"].append(result)
        job = None
        try:
            raw, _ = exchange(port, b"GET / HTTP/1.1\r\nHost: localhost\r\n\r\n", timeout=0.1)
            cookie = re.search(rb"Set-Cookie: ([^;\r]+)", raw).group(1).decode()
            result["samples"].append(sample(proc, "baseline"))
            cmd = [wrk, "-t2", "-c100", f"-d{duration}s", "--latency", "--timeout", "2s",
                   "-H", "Cookie: " + cookie, f"http://127.0.0.1:{port}/"]
            # All requests intentionally reuse one session; record this
            # explicitly because persistSession contends on its one stripe.
            result["session_mode"] = "one shared established session"
            job = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            while job.poll() is None:
                result["samples"].append(sample(proc, "load"))
                save()
                time.sleep(2)
            result["wrk_output"] = job.communicate()[0]
            result["wrk_exit_code"] = job.returncode
            print(label, result["wrk_output"], flush=True)
            for _ in range(6):
                time.sleep(2)
                result["samples"].append(sample(proc, "recovery"))
                save()
            data, ended = exchange(port, b"GET / HTTP/1.1\r\nHost: localhost\r\n\r\n")
            result["post_load_healthy"] = data.startswith(b"HTTP/1.1 200")
        finally:
            if job is not None and job.poll() is None:
                job.kill()
                job.wait()
            result["shutdown"] = stop(proc)
            save()


if __name__ == "__main__":
    print("Results:", OUT, flush=True)
    adversarial()
    load()
    print("Complete:", OUT, flush=True)
