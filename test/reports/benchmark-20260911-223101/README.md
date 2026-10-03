# Flux benchmark

Flux commit: `d863b653b5922e3a36475c8e374df79abbb5ce45`. Example server rebuilt before this run.
Platform: macOS-26.6.2-arm64-arm-64bit-Mach-O.

Existing `test/socket_suite.py` load workload: loopback GET `/`, two wrk
threads, 100 connections, 128 server connection limit, and one shared
established session. Includes the example application's middleware and logging.
One run per owner configuration; this is not a statistical capacity estimate.

| Event loops | Duration | Requests/sec | Mean latency | p99 latency | Peak sampled RSS |
| --- | --- | ---: | ---: | ---: | ---: |
| 1 | 30 s | 16,282.69 | 6.23ms | 11.29ms | 53.8 MiB |
| 2 | 60 s | 25,073.30 | 3.99ms | 6.38ms | 60.0 MiB |
| 4 | 30 s | 31,995.51 | 3.14ms | 6.28ms | 64.1 MiB |

All wrk processes exited 0 with no reported socket errors, timeouts, or
non-2xx/3xx responses. All post-load health checks passed. Every server
exited 0 without a forced kill. These results do not benchmark PostgreSQL.

`results.json` contains wrk output and resource samples. Full server logs remain
in `/var/folders/7x/qc57ddy15_zcrzvx3jdrprvw0000gn/T/flux-socket-suite-tt1zfjga`; they were not duplicated into the repository.

Reproduce from the Flux root after building `examples/examples.ipkg`:

```sh
python3 -u -c 'import sys; sys.path.insert(0, "test"); import socket_suite as s; print(s.OUT); s.load()'
```
