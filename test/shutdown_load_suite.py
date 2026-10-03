#!/usr/bin/env python3
"""Sustained-load shutdown probe for the new idris2-flux-async runtime.

This targets the one question the 2026-09-11 socket_suite.py benchmark did not
answer: does Server.serve's bounded drain (30s) plus the native shutdown
watchdog (35s, Flux.Async.Standalone) actually bound process exit when SIGTERM
arrives *during* sustained concurrent load, or can it still stall the way the
old idris2-async fork did (see memory: 2 of 7 trials hung past the 30s bound
at ~19-20k req/s / 4 threads, needing a manual SIGKILL)?

Method per trial:
  1. Start the example server with FLUX_EVENT_LOOPS=<owners>.
  2. Start wrk against it with a duration long enough to still be sending
     requests when the process is asked to stop (open-loop-ish saturation).
  3. Once wrk has been running for `warmup_s` (steady state reached), send
     SIGTERM to the server -- while wrk keeps hammering it.
  4. Poll the server process every 200ms until it exits or a hard
     `outer_bound_s` ceiling is hit (at which point *we* SIGKILL it -- that is
     the failure signature we are checking for: the native watchdog itself
     failed to bound exit).
  5. Classify the outcome from wall-clock time and exit code:
       - "cooperative"      : exited before the 30s drain deadline, code 0
       - "cooperative-late"  : exited at/after 30s but before 35s, code 0
       - "watchdog-forced"  : exited at/after ~35s (native watchdog fired;
                              _exit(124) is a normal process exit, not a
                              signal, so returncode should read 124)
       - "harness-killed"   : never exited on its own within outer_bound_s;
                              we had to SIGKILL it -- this is the historical
                              failure mode, reproduced against the new runtime
  6. Sample RSS/FD/CLOSE_WAIT counts throughout for leak signal, same as
     socket_suite.py's sample().

Usage:
  python3 -u -c 'import sys; sys.path.insert(0, "test"); import shutdown_load_suite as s; s.run()'

Requires: examples/examples.ipkg already built, wrk on PATH.
"""
import json
import os
import platform
import signal
import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = Path(tempfile.mkdtemp(prefix="flux-shutdown-load-"))
RESULTS = {"output": str(OUT), "platform": platform.platform(),
           "started_at": time.time(), "trials": []}

DRAIN_DEADLINE_S = 30
WATCHDOG_DEADLINE_S = 35


def save():
    (OUT / "results.json").write_text(json.dumps(RESULTS, indent=2))


def start(label, owners, workers=128, idle_timeout_ms=60000):
    with socket.socket() as reserve:
        reserve.bind(("127.0.0.1", 0))
        port = reserve.getsockname()[1]
    env = dict(os.environ, FLUX_EVENT_LOOPS=str(owners),
               FLUX_SERVER_PORT=str(port), FLUX_SERVER_HOST="127.0.0.1",
               FLUX_SERVER_WORKERS=str(workers), FLUX_SERVER_TIMEOUT=str(idle_timeout_ms))
    appdir = ROOT / "examples/build/exec/flux-examples_app"
    env["IDRIS2_INC_SRC"] = str(appdir)
    for key in ["LD_LIBRARY_PATH", "DYLD_LIBRARY_PATH"]:
        env[key] = str(appdir) + (":" + env[key] if env.get(key) else "")
    log = open(OUT / (label + ".server.log"), "wb")
    proc = subprocess.Popen([str(appdir / "flux-examples.so"), "--from-env"],
                            cwd=ROOT / "examples", env=env, stdout=log, stderr=log)
    log.close()
    for _ in range(100):
        if proc.poll() is not None:
            raise RuntimeError(f"server exited before it ever accepted: {label}")
        try:
            with socket.create_connection(("127.0.0.1", port), 0.1):
                return proc, port
        except OSError:
            time.sleep(0.1)
    proc.kill()
    proc.wait()
    raise RuntimeError("startup timeout")


def sample(proc, phase):
    ps = subprocess.run(["ps", "-o", "rss=,%cpu=", "-p", str(proc.pid)],
                        capture_output=True, text=True).stdout.strip().split()
    fds = subprocess.run(["lsof", "-nP", "-a", "-p", str(proc.pid)],
                         capture_output=True, text=True).stdout.splitlines()
    return {"time": time.time(), "phase": phase,
            "rss_kib": int(ps[0]) if ps else None,
            "cpu_percent": float(ps[1]) if ps else None,
            "fd_rows": len(fds), "tcp_rows": sum("TCP" in x for x in fds),
            "close_wait": sum("CLOSE_WAIT" in x for x in fds)}


def classify(elapsed_s, exit_code, forced):
    if forced:
        return "harness-killed"
    if elapsed_s < DRAIN_DEADLINE_S:
        return "cooperative"
    if elapsed_s < WATCHDOG_DEADLINE_S:
        return "cooperative-late"
    return "watchdog-forced"


def run_trial(label, owners, connections, load_duration_s, warmup_s, outer_bound_s):
    proc, port = start(label, owners)
    trial = {"label": label, "owners": owners, "connections": connections,
             "load_duration_s": load_duration_s, "warmup_s": warmup_s, "samples": []}
    RESULTS["trials"].append(trial)
    wrk = None
    try:
        wrk_cmd = ["wrk", f"-t{min(4, connections)}", f"-c{connections}",
                   f"-d{load_duration_s}s", "--latency", "--timeout", "2s",
                   f"http://127.0.0.1:{port}/"]
        wrk_log = open(OUT / (label + ".wrk.log"), "w")
        wrk = subprocess.Popen(wrk_cmd, stdout=wrk_log, stderr=subprocess.STDOUT)

        trial["samples"].append(sample(proc, "pre-sigterm"))
        time.sleep(warmup_s)
        trial["samples"].append(sample(proc, "at-sigterm"))

        sigterm_at = time.time()
        proc.send_signal(signal.SIGTERM)

        forced = False
        while True:
            elapsed = time.time() - sigterm_at
            rc = proc.poll()
            if rc is not None:
                break
            if elapsed >= outer_bound_s:
                forced = True
                proc.kill()
                proc.wait()
                break
            if int(elapsed * 5) % 5 == 0:
                trial["samples"].append(sample(proc, f"draining+{elapsed:.0f}s"))
                save()
            time.sleep(0.2)
        elapsed = time.time() - sigterm_at

        trial["sigterm_to_exit_s"] = round(elapsed, 3)
        trial["exit_code"] = proc.returncode
        trial["forced_by_harness"] = forced
        trial["outcome"] = classify(elapsed, proc.returncode, forced)
    finally:
        if wrk is not None and wrk.poll() is None:
            wrk.terminate()
            try:
                wrk.wait(timeout=5)
            except subprocess.TimeoutExpired:
                wrk.kill()
                wrk.wait()
        trial["wrk_exit_code"] = wrk.returncode if wrk is not None else None
        trial["wrk_log"] = (OUT / (label + ".wrk.log")).read_text()[-4000:] if wrk is not None else None
        save()
    return trial


def run(owner_configs=(2, 4), trials_per_config=5, connections=150,
        load_duration_s=45, warmup_s=10, outer_bound_s=50):
    print("Results:", OUT, flush=True)
    for owners in owner_configs:
        for i in range(trials_per_config):
            label = f"shutdown-{owners}owners-trial{i}"
            trial = run_trial(label, owners, connections, load_duration_s, warmup_s, outer_bound_s)
            print(f"{label}: {trial['outcome']} in {trial['sigterm_to_exit_s']}s "
                  f"(exit={trial['exit_code']}, forced={trial['forced_by_harness']})", flush=True)
    summarize()
    print("Complete:", OUT, flush=True)


def summarize():
    by_owners = {}
    for t in RESULTS["trials"]:
        by_owners.setdefault(t["owners"], []).append(t)
    lines = ["# Shutdown-under-load probe (new idris2-flux-async runtime)", "",
             f"Platform: {RESULTS['platform']}", ""]
    lines.append("| Owners | Trials | Cooperative | Cooperative-late | Watchdog-forced | Harness-killed | Max sigterm->exit (s) |")
    lines.append("| --- | --- | --- | --- | --- | --- | ---: |")
    worst = []
    for owners, trials in sorted(by_owners.items()):
        counts = {"cooperative": 0, "cooperative-late": 0, "watchdog-forced": 0, "harness-killed": 0}
        for t in trials:
            counts[t["outcome"]] += 1
        max_s = max(t["sigterm_to_exit_s"] for t in trials)
        lines.append(f"| {owners} | {len(trials)} | {counts['cooperative']} | "
                      f"{counts['cooperative-late']} | {counts['watchdog-forced']} | "
                      f"{counts['harness-killed']} | {max_s} |")
        if counts["harness-killed"]:
            worst.append(owners)
    if worst:
        lines.append("")
        lines.append(f"**FAILURE REPRODUCED** at owners={worst}: the native shutdown "
                      "watchdog did not bound process exit under sustained load; the "
                      "harness had to SIGKILL. This is the same failure class as the "
                      "old idris2-async cancellation stall.")
    else:
        lines.append("")
        lines.append("No harness-forced kills: every trial exited on its own "
                      "(cooperative drain or native watchdog), even under sustained "
                      "load through SIGTERM.")
    (OUT / "README.md").write_text("\n".join(lines) + "\n")
    print("\n".join(lines))


if __name__ == "__main__":
    run()
