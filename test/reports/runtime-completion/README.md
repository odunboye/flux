# Runtime completion attempt

Baseline: Flux checkpoint `b432953`. The original failed attempt is preserved
below. **Final follow-up regression passes** with the SHA-256 optimization
in companion `idris2-pg` commit `2e22c85078578d8128fecf1a489d700f7675fb15`.
This Flux checkpoint preserves the reproduction scripts and verification records.

## Final follow-up

`final/macos.exit` and `final/linux.exit` are both 0. Each platform passed:

- 163 PG unit checks (including six added SHA-256 padding/block-boundary vectors),
  crypto properties, and real-database integration.
- Runtime, service, stream, socket, and native ASan/UBSan checks.
- Flux regressions and live HTTP protocol/shutdown probes.
- 24 pooled todo-api checks and 3,360 checked HTTP requests each with 1, 2,
  and 4 owners, all followed by clean shutdown.

macOS additionally passed the 15-check pool suite, isolated TLS deadline/reuse
checks, and Nebula integration. The Linux ordinary PG integration TLS case
skipped because its database has SSL disabled. Linux native sanitizer tests
used `ASAN_OPTIONS=detect_leaks=0` under emulation; this is not a leak check.

Drivers and per-suite logs are saved in `final/`. The macOS driver initially
ran before its disposable database existed; that setup failure is preserved
as `macos-pg-integration-setup-failure.log`. After database provisioning, the
entire driver was rerun successfully. The macOS DB container is
`flux-final-macos-pg`, published only on `127.0.0.1:5432`; the other two
containers remain as described below. No unrelated application DB was used.

The optimization replaces repeated linked-list indexing/copying in SHA-256's
schedule and rounds with reversed schedule construction and sequential round
traversal. SHA-256 outputs, SCRAM iterations, and five-second pool deadlines
are unchanged. PostgreSQL logs before the optimization measured about 2.6
seconds per authentication, leaving insufficient budget for another serialized
cold connection. This is a demonstrated performance-sensitive failure, not
proof of a general Docker runtime defect. Native Linux performance is untested.
The prior two-hour HTTP soak was not repeated after the crypto optimization.

## Results

- `macos-todo-one-owner.log`: 24 clients, 480 CRUD lifecycles, 3,360 checked
  requests; clean shutdown. Default five-second pool acquisition deadline.
- `linux-runtime.log`: runtime, service, stream, and socket suites pass.
  Includes byte-exact binary transfer, large-payload backpressure, EOF, and
  accept cancellation. Installing Python resolved the prior driver blocker.
- `macos-flux-build.log`, `macos-flux-regression.log`: build and regression
  executable exit successfully; all reported checks pass.
- `macos-protocol.log`: live protocol and shutdown assertions pass.
- `linux-application.log`: full-stack source build and all 24 pooled repository
  checks pass; live one-owner HTTP check fails with HTTP 500, logged as
  `connection error: connection timed out`.
- `linux-todo-one-owner-retry.log`: same failure on retry.
- `linux-todo-numeric-host.log`: same failure using the DB container's numeric
  address instead of Docker DNS.
- `linux-todo-multiple-owners.log`: same failure with two and four owners.

Linux environment: `ghcr.io/stefan-hoeck/idris2-pack:latest`, image ID
`e60bc168d029`, explicitly `linux/amd64` under emulation on an ARM Mac.
Pack collection `nightly-260906`, Idris2 0.8.0 commit
`5aaefadb587224eb44d3be0fbb7e2835b48bd7a6`. PostgreSQL 16.15 runs in a
separate ARM Linux container with default SCRAM-SHA-256 (4096 iterations).
No production code or timeout settings were changed for these checks.

## Reproduction

Run from the Flux repository. The Linux application suite resets its test
schema: use only the disposable database below, never application data.

```sh
mkdir -p test/reports/runtime-completion
TODO_API_SKIP_DOCKER=1 python3 ../../playground/todo-api/test/runtime_http_test.py --owners 1
pack build test/test.ipkg
./test/build/exec/flux-test
python3 test/runtime_protocol_test.py

# Use unique names if these already exist.
docker network create flux-mission-test
docker run -d --name flux-mission-linux --platform linux/amd64 \
  --network flux-mission-test -v "$(cd ../.. && pwd):/workspace:ro" \
  --entrypoint sh ghcr.io/stefan-hoeck/idris2-pack:latest -c 'sleep infinity'
docker exec -e DEBIAN_FRONTEND=noninteractive flux-mission-linux sh -c \
  'apt-get update && apt-get install -y python3 libssl-dev'
docker exec flux-mission-linux sh -c \
  'ln -s /root/.cache/pack/git/github.com/stefan-hoeck/idris2-quantifiers-extra /quantifiers; sh /workspace/libs/idris2-flux-async/test/linux_runtime.sh'
docker run -d --name flux-mission-pg --network flux-mission-test \
  -e POSTGRES_USER=testuser -e POSTGRES_PASSWORD=testpass \
  -e POSTGRES_DB=todo_api_test postgres:16
# Wait for pg_isready to succeed before running the application checks.
docker exec flux-mission-pg pg_isready -U testuser -d todo_api_test
docker exec -e PG_TEST_HOST=flux-mission-pg flux-mission-linux \
  sh /workspace/projects/flux/test/linux_application.sh
```

The application script builds in `/tmp/flux-application`, leaving the mounted
workspace untouched, and stops on the first failed check. To reproduce the
other owner counts after that failure:

```sh
docker exec -e PG_TEST_HOST=flux-mission-pg -e TODO_API_SKIP_DOCKER=1 \
  flux-mission-linux sh -c \
  'cd /tmp/flux-application/playground/todo-api; python3 test/runtime_http_test.py --owners 2'
# Repeat with --owners 4.
```

## Checkpoint scope

The companion SHA-256 optimization and regression vectors are committed in
`idris2-pg` as linked above. The originally failing Docker workload now passes
without increasing deadlines, warming the pool, or weakening authentication.
Production readiness and native Linux performance remain separate from
completion of these runtime-migration verification gates.

Cleanup only the disposable resources created above when finished:

```sh
docker rm -f -v flux-mission-linux flux-mission-pg flux-final-macos-pg
docker network rm flux-mission-test
```
