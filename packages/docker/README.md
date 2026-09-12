# flux-docker

A small library for managing Docker containers from Idris2 - the common
dev-workflow need of "make sure this one dependency container (a
database, a queue, ...) is running before my app or tests start", not a
general Docker API client.

Built entirely on Idris2 `base`'s own `System.Escaped.run`/
`System.Escaped.system` (`popen`- and libc-`system()`-backed
respectively) - no new dependency beyond `base` itself, no FFI of its
own.

## Install / build

Requires [pack](https://github.com/stefan-hoeck/idris2-pack) and a local
Docker daemon.

```sh
pack install flux-docker
```

Or, from the Flux repository root:

```sh
pack build packages/docker/flux-docker.ipkg
```

## Usage

```idris
import Docker

pgSpec : ContainerSpec
pgSpec = MkContainerSpec
  "my-app-pg"
  "postgres:16"
  [("POSTGRES_USER", "myuser"), ("POSTGRES_PASSWORD", "mypass"), ("POSTGRES_DB", "mydb")]
  [(5432, 5432)]

main : IO ()
main = do
  ok <- available
  if not ok
     then putStrLn "Docker isn't available - skipping"
     else do
       Right () <- ensureRunning pgSpec
         | Left code => putStrLn "docker failed, exit code \{show code}"
       putStrLn "Postgres container is up"
```

`ensureRunning` is idempotent: creates the container if it doesn't exist,
starts it if it exists but is stopped, does nothing if it's already
running - safe to call on every app startup.

### API

- `available : IO Bool` - is the `docker` CLI installed *and* the daemon
  reachable? Check this first if you want to distinguish "Docker just
  isn't in the picture" from a real container-level problem; every other
  function here will still try to shell out to `docker` regardless of
  what this returns.
- `inspect : String -> IO ContainerState` (`NotFound | Stopped |
  Running`) - `NotFound` covers both "no such container" and "docker
  itself isn't usable right now".
- `run : ContainerSpec -> IO (Either Int ())` - `docker run -d --name ...`.
  `Left` carries docker's own nonzero exit code; its own diagnostic (e.g.
  "port is already allocated") reaches your terminal directly, uncaptured.
- `start`/`stop`/`remove : String -> IO (Either Int ())`.
- `publishedPort : String -> Nat -> IO (Maybe Nat)` - the host port Docker
  published for a given container port, if the container is running and
  that mapping exists. Useful for noticing "this container is up, but
  bound to a different port than I expected" (a stale container from an
  old config, say) instead of a silent, confusing connection timeout
  later.
- `ensureRunning : ContainerSpec -> IO (Either Int ())` - the convenience
  combinator above.

### What this deliberately doesn't do

- **No readiness/health-waiting.** "Is the service *inside* the
  container actually ready" is protocol-specific - a raw TCP connect
  succeeding doesn't mean Postgres has finished its auth handshake, for
  instance. That's left to the caller, using whichever client library
  already knows how to ask the real question (e.g. retrying a real
  `connectDB` in a bounded loop, for Postgres - see
  [`todo-api`](https://github.com/odunboye/flux)'s own `DevPostgres.idr`
  for a worked example built on this library).
- **No volumes, networks, or arbitrary extra `docker run` flags.**
  `ContainerSpec` covers name/image/env/port-mappings - the common case
  for a dev-dependency container. If you need more, shell out yourself
  (`System.Escaped.system`/`run`, both from `base` - this library doesn't
  wrap anything you can't reach directly) rather than expecting this
  library to grow into a full Docker CLI wrapper.
- **No automated teardown on your app's exit.** Stopping/removing a
  container your app started is a decision for the caller to make
  explicitly (`stop`/`remove` are right there) - auto-stopping on every
  process exit would be a surprising way to lose a local dev database's
  data between runs.

## Running the tests

Needs a real local Docker daemon (tests are skipped, not failed, if
`available` reports `False` - see `test/src/Main.idr`'s `main`).

```sh
cd test
pack build test.ipkg
./build/exec/flux-docker-test
```

Uses a small, fast image (`busybox`), not Postgres or anything specific
to a consumer's use case - exercises every function above against a real
container, and cleans it up afterward regardless of whether the run
passed or failed.
