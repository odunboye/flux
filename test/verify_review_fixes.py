#!/usr/bin/env python3
"""Run only protocol probes plus nested-symlink regression checks."""
import json
from pathlib import Path
import tempfile
import socket_suite as suite

print("Results:", suite.OUT, flush=True)
suite.adversarial()
fixture = Path(tempfile.mkdtemp(prefix="flux-nested-symlink-"))
public = fixture / "public"
public.mkdir()
outside = fixture / "outside"
outside.mkdir()
(outside / "secret.txt").write_text("OUTSIDE_ROOT_CANARY_9394efe\n")
(public / "inside.txt").write_text("INSIDE_ROOT_CONTROL\n")
(public / "jump").symlink_to(outside, target_is_directory=True)
(public / "indirect.txt").symlink_to("jump/secret.txt")
(public / "direct.txt").symlink_to(outside / "secret.txt")
proc, port = suite.start("symlink-verification", 2, cwd=fixture)
results = []
try:
    for name in ["inside.txt", "direct.txt", "jump/secret.txt", "indirect.txt"]:
        raw = f"GET /static/{name} HTTP/1.1\r\nHost: localhost\r\n\r\n".encode()
        response, ended = suite.exchange(port, raw)
        result = {"path": name, "response": response.decode("latin1"),
                  "outside_content_exposed": b"OUTSIDE_ROOT_CANARY" in response,
                  "end": ended}
        results.append(result)
        print(name, response.split(b"\r\n", 1)[0], "outside_content_exposed", result["outside_content_exposed"], flush=True)
finally:
    shutdown = suite.stop(proc)
suite.RESULTS["symlink_checks"] = results
suite.RESULTS["symlink_fixture"] = str(fixture)
suite.RESULTS["symlink_shutdown"] = shutdown
suite.save()
destination = Path(__file__).parent / "reports/2026-09-09-fix-verification.json"
destination.write_text(json.dumps(suite.RESULTS, indent=2))
print("Saved:", destination, flush=True)
