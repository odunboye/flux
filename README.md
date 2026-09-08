# flux

An HTTP/1.1 server framework for Idris2, built from scratch on top of
[`idris2-streams`](https://github.com/stefan-hoeck/idris2-streams)'
`async`/`streams-posix` — no C server library, no FFI to an existing web
server. The wire protocol (request parsing, persistent connections,
chunked transfer-encoding), the router, the middleware/`Context` pipeline,
and everything built on top of them (JSON, cookies, sessions, static
files, health checks) are all implemented directly in this repo.

## Project goals

The goal is a **usable, honestly-documented** framework: routing,
middleware, JSON, cookies/sessions, static files, structured error
handling and streaming responses all work and are tested (115 unit tests,
`test/`). What sets this README apart from a typical framework's docs is
that every non-obvious tradeoff, gap, and half-solved problem uncovered
while building it is written down rather than smoothed over — see
"Limitations" below. Several of those gaps trace back to real bugs found
in the underlying `idris2-async` scheduler while load-testing this
project; where a bug couldn't be fixed safely, what's documented here is
the mitigation actually shipped and the tradeoff it represents, not a
claim that the underlying issue is solved.

## Install / build

Requires [pack](https://github.com/stefan-hoeck/idris2-pack).

```sh
pack build flux.ipkg
```

The example server:

```sh
pack build examples/examples.ipkg
./examples/build/exec/flux-examples 8080 128   # port, worker count
```

## Usage

```idris
import Flux

record User where
  constructor MkUser
  id   : Integer
  name : String

ToJSON User where
  toJSON u = JObject (fromList [("id", toJSON u.id), ("name", toJSON u.name)])

getUser : Handler
getUser ctx = case getParam "id" ctx.pathParams of
  Just "1" => pure (sendJSON (MkUser 1 "Ada") ctx)
  _        => throw (MkAppError 404 "user not found")

buildApp : App
buildApp =
  app
    |> withErrorRenderer jsonErrorRenderer
    |> use secureHeaders
    |> withRoutes (empty |> get "/api/users/:id" getUser)

main : IO ()
main = do
  _ :: args <- getArgs | [] => runProg (runServerArgs (runApp buildApp) [])
  runProg (runServerArgs (runApp buildApp) args)
```

See `examples/src/Main.idr` for a fuller demo exercising the whole
feature set (path params, query strings, PUT/DELETE, `AppError` rendered
as JSON, cookies/sessions, static files, graceful shutdown), and
`examples/src/EchoServer.idr` for the lowest-level way to use this
project — a `Responder` with no router or middleware at all.

## Routing

`Flux.Core.Router`'s `Router h` is a plain ordered list of routes,
matched first-match-wins in registration order via `get`/`post`/`put`/
`delete`/`patch`/`options_`/`head_`. Path patterns support `:name`
(a single segment, bound into `PathParams`) and a trailing `*name`
splat that consumes every remaining segment (joined with `/`) — used for
static file serving. `matchRoute` returns a 3-way `MatchResult`
(`Matched`/`WrongMethod`/`NoMatch`) so a genuine 405 (with a correct
`Allow` header, listing every method some route in the table would have
accepted for that path) is distinguishable from a 404 — most minimal
routers collapse those into one case.

Matching is a linear scan of the route list on every request — fine for
the size of route table a typical app has, but there's no trie/radix
optimization, so a very large route table pays O(routes) per request.

## Middleware & Context

`Handler`/`Middleware` are both `Context -> AppProg Context`, where
`AppProg = Async Poll [Errno, AppError]`. `App` holds a router plus
`before`/`after` middleware lists (`use`/`useAfter`) and an
`ErrorRenderer` (`withErrorRenderer`); `runApp : App -> Responder` runs
before-middleware, dispatches to the matched handler (or 404/405),
then after-middleware, and renders the result to wire bytes.

Any `AppError` thrown along the way (`throw (MkAppError status msg)`) is
caught and rendered via `onError`, onto a **fresh** `Context` — a
before-hook that mutated the context and then something downstream threw
does not get to keep those mutations in the error response. Any other
failure (`Errno`, from a lower-level IO error inside a handler) is also
caught, not left to silently drop the connection with zero bytes sent —
it renders as a generic 500 through the same `onError`. Two renderers ship:
`defaultErrorRenderer` (plain text) and `Flux.Data.JSON.jsonErrorRenderer`
(`{"error": "..."}`).

Responses are either fully buffered (`send`/`sendText`/`sendJSON`) or
streamed (`sendStream (Just len) body` for a known length, `sendStream
Nothing body` to chunk-transfer-encode a body of unknown length —
`Flux.Core.HTTP.chunkEncode` implements RFC 7230 chunked framing directly).
`Flux.Middleware.Static.staticHandler` is built on `sendStream`, so a
static file is streamed off disk (`readBytes`), not buffered in memory
before it's sent.

**Request bodies are not reachable from this layer.** `Context.request.body`
is an `HTTPBody` (`AsyncPull Poll ByteString [Errno,HTTPErr] (HTTPStream
ByteString)`) — a `Pull`-effect computation — but `Handler`/`Middleware`
live in plain `AppProg` (`Async Poll [Errno,AppError]`), which has no
combinator for running a `Pull` and getting bytes back. There is no
helper anywhere in this codebase to read a POST/PUT body from a router
`Handler`. The only place a request body is actually consumed is the
low-level `Responder` driver itself (`respondWith` always drains it after
your `Responder` runs, to keep a persistent connection's byte stream in
sync for the next request) — see `EchoServer.idr` for the one place in
this repo that touches a body at all, and note it does so by *not* being
a router-based `App`. Building JSON/form-body-reading support for real
handlers is unstarted work, not a small gap.

## JSON

`Flux.Data.JSON` is a small, dependency-free `JSON` value type plus a
hand-written recursive-descent parser/encoder and `ToJSON`/`FromJSON`
interfaces (instances for `Bool`/`Int`/`Integer`/`Double`/`String`/`JSON`/
`List a`/`SortedMap String a`). `JNumber` is a `Double` — no distinct
integer representation, so a JSON integer round-trips through a float
(exact up to 2^53, same caveat as JavaScript's `JSON.parse`). The parser
has no depth limit and is not resistant to pathological input (deeply
nested arrays/objects) — it hasn't been fuzzed or hardened against
adversarial payloads, just tested against well-formed ones (12 unit
tests, `test/src/TestJSON.idr`).

## Config

`Flux.Server.Config` can build a `Config` from environment variables with
a given prefix (`loadFromEnv "FLUX_"`: `FLUX_SERVER_PORT=9090` becomes key
`"server.port"`) and parse a `ServerConfig`/`AppInfo` out of it.

**`ServerConfig`'s fields are not connected to the server.** `host`,
`workers`, `timeout`, and `maxBodySize` are all real, gettable/settable
fields with env-loading support — but nothing in `Flux.Core.HTTP` reads
any of them. The actual server is configured by `runServerArgs`'s CLI
`[port, workers]` args (or by calling `runServer`/`app`/`posixPoller`
directly), not by `ServerConfig`. The real request-size limits are
hardcoded constants in `Flux.Core.HTTP` — `MaxHeaderSize = 0xffff` (64KB)
and `MaxContentSize = 0xffff_ffff` (~4GB) — not `ServerConfig.maxBodySize`,
which currently does nothing regardless of what it's set to. `Config`
itself is fully functional as a generic env-var-backed key/value store
(12 unit tests, `test/src/TestConfig.idr`); it's specifically the
`ServerConfig`/`AppInfo` wiring into the actual running server that's
missing.

## Logging

`Flux.Server.Logging` ships two sinks. `mkLogger` writes every line
immediately (`putStrLn`) — simplest, but every worker thread's requests
contend on the same stdout, and that contention becomes the whole
server's bottleneck once more than one async worker thread is genuinely
running requests in parallel (measured: a request-ID+session-only
middleware stack held ~22.4k req/s at 4 worker threads; adding one
`mkLogger` call per request dropped that to ~484 req/s). `BatchedLogger`
buffers formatted lines and flushes them periodically
(`flushLoop`/`flushNow`) off the request path, but still *builds* the
formatted string on the request-handling thread — under real concurrency
that's still a bottleneck (throughput as low as ~300-500 req/s at 2-4
threads), because Chez's multi-threaded allocator/GC contends heavily on
concurrent string-building specifically, not on the shared buffer itself
(striping the buffer 16 ways, the same fix that worked for request-ID/
session counters, did not fix this).

`BatchedAccessLog` (paired with `Flux.Middleware.Timing.requestAccessLog`)
is the one to actually use for the per-request access log: it buffers the
*raw* `HTTPLogContext` record and defers all string formatting to
`flushAccessLog`, which runs on a single background thread. Measured
directly in Chez (no Idris2 involved): appending a built string to a
shared cell scales 4.5M → 568K → 194K → 181K ops/sec at 1/2/4/8 threads;
appending a small fixed-size record instead (no string built at all)
scales 20.1M → 21.0M → 13.0M → 4.8M — 25-90x better at every thread
count, and it actually improves from 1 to 2 threads instead of
immediately collapsing. Both batched loggers share the same tradeoff:
whatever's buffered when the process dies (crash, `kill -9`, power loss)
is lost — up to one flush interval's worth. Not acceptable for an audit
trail; fine for an access log.

## Health checks

`Flux.Server.Health` provides `/health`, `/healthz`, `/ready`, `/live`,
`/startup` routes (`healthRoutes`) backed by a `HealthRegistry` of
`IO CheckResult` checks. **The five "standard" checks
(`databaseCheck`, `cacheCheck`, `externalServiceCheck`, `memoryCheck`,
`diskCheck`) are placeholders that always report `Healthy`** — none of
them touch a real database, cache, or the actual process's memory/disk
usage. `registerStandardChecks` wires all of them in, so a server using
it will always report healthy regardless of actual state unless you
write and register your own `HealthCheck`s.

## Cookies & sessions

`Flux.Middleware.Cookies` parses the `Cookie` request header and renders
`Set-Cookie` (`cookie` gives sane defaults: root path, `HttpOnly`,
session-lifetime, not `Secure` — set `{ secure := True }` explicitly for
TLS). `Flux.Middleware.Session` builds an in-memory, cookie-backed session
store on top of it, sharded 16 ways the same way request IDs are (see
"Concurrency" below).

This is explicitly a minimal implementation, documented as such in the
module itself: sessions never expire and are never garbage-collected — a
long-running server accumulates one entry per distinct visitor forever —
and session IDs are a process-local counter (`"sess-<stripe>-<n>"`), not
a cryptographically random token (this dependency stack has no obvious
CSPRNG), so they're guessable. Fine for a demo or low-stakes app; not an
unforgeable auth credential without real hardening (a proper random ID,
expiry, and a persistent store).

## Static files

`Flux.Middleware.Static.staticHandler root mimeFor`, mounted under a
splat route (`get "/static/*path" (staticHandler "public" defaultMimeFor)
router`). Guards against path traversal (rejects `..` segments and a
leading `/` in the resolved relative path — tested,
`test/src/TestStatic.idr`), checks the file exists up front (open, then
immediately close) so a missing file gets a clean 404 instead of failing
mid-stream, and streams the body via `readBytes` rather than buffering
the whole file. `defaultMimeFor` covers common web/text/image types,
falling back to `application/octet-stream`.

## Concurrency: async worker threads

The server accepts connections via `foreachPar`, one fiber per
connection, driven by `async-posix`'s POSIX `poll()`-based scheduler.
`Flux.Core.HTTP.defaultAsyncThreads` reads `IDRIS2_ASYNC_THREADS` and
defaults to **2** threads if it isn't set. That default reflects real,
repeatedly-verified benchmarking (`wrk`, this project's example server,
100 concurrent connections, server process fully restarted between
trials to rule out measurement artifacts): 2 threads is reliably ~2x
faster than 1 (~21k req/s vs ~44k). Going *past* 2 collapses throughput
catastrophically — 4 threads measured ~1.5k req/s, 8 threads ~0.9k, each
additional thread beyond 2 making things worse, not better.

That cliff is a real, unfixed bug in `idris2-async`'s scheduler: every
fiber forked from the accept loop is pinned to whichever worker happens
to be running the accept loop at the time, so beyond a couple of workers
most sit permanently idle while one or two do all the work, and the
resulting contention/queueing overhead outweighs any parallelism gained.
A fix (round-robin fiber scheduling instead of pinning, in a fork of
`idris2-async`) was built and benchmarked, and reverted — it was found to
dramatically worsen a separate, rare (~5% of idle-connection gaps in
testing), not-fully-root-caused connection-leak race already present
upstream in the same scheduler. Until that's fixed safely, stay at the
default of 2 threads; only raise it if your own workload doesn't hit this
cliff (confirm with your own benchmark, restarting the server between
trials the same way — an earlier round of this project's own testing
initially reported a *worse* number for 2 threads specifically, which
turned out to be a benchmarking-harness bug: an orphaned server process
from a prior trial kept answering requests on the same port across a
supposedly clean restart).

### The rare connection-leak race and its mitigation

The leak above (present in stock upstream `idris2-async`, independent of
the thread-count issue) is mitigated, not fixed, at this layer:
`serveWith` wraps every connection in `idleTimeout` (`Flux.Core.HTTP`), a
watchdog fiber that cancels a connection if a shared "activity" counter
hasn't moved in `idleConnectionTimeout` (default 60s). Bounded testing
(back-to-back `wrk` runs against one long-lived process) confirms this
works: leaked file descriptors and `CLOSE_WAIT` sockets accumulate under
load but get reaped within roughly one to two timeout windows, dropping
to zero once load stops, rather than growing without bound. Set
`idleConnectionTimeout` lower if you need a tighter bound and can accept
more false positives against genuinely slow (but not stuck) clients; it
isn't currently exposed as server-level config (see the `ServerConfig`
gap above).

### Memory growth under sustained load

Separately from the connection leak, resident memory grows steadily under
sustained load and does not fully return to baseline once idle — observed
even with **zero** connection leak present (reproduced identically at
`IDRIS2_ASYNC_THREADS=1`, where `CLOSE_WAIT`/FD counts stayed flat the
entire time: RSS still climbed from ~122MB to ~778MB over ten 15s `wrk`
rounds, and 90s fully idle afterward left it unchanged). This rules out
both an application-level buffer bug (`BatchedAccessLog`'s flush loop
correctly drains its buffer every tick) and the connection leak as the
cause. The leading explanation, not fully confirmed, is Chez Scheme's
generational GC retaining committed heap pages as a high-water mark
rather than returning them to the OS — consistent with this project's
other findings about Chez's allocator behaving unusually under
concurrent load (see "Logging" above). Not confirmed: whether this
plateaus at a working-set size under much longer sustained load (hours,
not minutes) or grows slowly without bound — that needs a longer soak
test or real heap-inspection tooling, neither done here.

## Graceful shutdown

`shutdownOn [SIGINT, SIGTERM]` (wired into `runServer`/`runProgWith`)
stops accepting new connections on either signal while letting in-flight
connections finish (`foreachPar`'s internal semaphore-drain blocks until
they do) — there's no shutdown timeout, so a stuck handler blocks exit
indefinitely.

**This does not work on macOS.** It relies on `async-posix`'s
`awaitSignals`, which calls the POSIX.1b `sigwaitinfo()` syscall — a
syscall the `posix` package's C support explicitly excludes on Darwin.
Sending SIGINT or SIGTERM to a running Flux server on macOS crashes it
(`Exception in foreign-procedure: no entry for "li_sigwaitinfo"`) instead
of shutting down cleanly, a pre-existing limitation of the dependency
stack (the same crash already happened with plain SIGINT before
`shutdownOn` existed). Verify graceful shutdown on Linux; there's no
unit test for it (not realistic for OS-signal behavior) — see
`examples/src/Main.idr`'s `/slow` handler for the manual verification
steps.

## Errors

Handler/middleware code sees `AppError` (`throw (MkAppError status msg)`,
caught and rendered via `App.onError`) and `Errno` (any lower-level IO
failure, also caught and rendered as a generic 500 rather than dropping
the connection). Wire-level parsing errors (`HTTPErr`: malformed request
line, oversized headers, oversized content-length) are handled entirely
inside the driver (`Flux.Core.HTTP`) below the `App`/`Handler` layer —
app code never sees them; a malformed request just gets a bare 400.

## Running the tests

```sh
pack build test/test.ipkg
./test/build/exec/flux-test
```

115 tests across 9 suites (router, HTTP wire parsing, JSON, middleware,
logging, config, cookies, sessions, static files) — all pure/unit-style,
no real socket or database involved. Nothing here exercises the server
driver end-to-end over a real connection; that's covered by manual
`curl`/`wrk` testing against `examples/`, not the automated suite.

There's no CI workflow configured for this repo yet (`pack build` +
`flux-test` locally is the only automated check today).

## Features

- [x] HTTP/1.1 with persistent connections (keep-alive), pipelining-safe
      request framing
- [x] GET/POST/HEAD/PUT/DELETE/PATCH/OPTIONS, path params (`:id`) and
      splat params (`*path`), query strings
- [x] Router with proper 404 vs 405 (`Allow` header) distinction
- [x] Middleware pipeline (`before`/`after`), typed `AppError` handling
      caught and rendered without dropping the connection
- [x] Streaming/chunked responses (`sendStream`), used by static file
      serving
- [x] JSON encode/decode, `ToJSON`/`FromJSON`, JSON error rendering
- [x] Cookies, in-memory sessions (sharded, not production-hardened —
      see "Cookies & sessions")
- [x] Static file serving with path-traversal protection
- [x] Health/liveness/readiness/startup routes (checks are placeholders
      by default — see "Health checks")
- [x] Env-var config loading (`Config`; not yet wired to the server
      itself — see "Config")
- [x] Two logging strategies (immediate vs batched/format-on-flush), with
      measured concurrency tradeoffs for each — see "Logging"
- [x] Graceful shutdown on SIGINT/SIGTERM (Linux only — see "Graceful shutdown")
- [x] An idle-connection timeout mitigating a known upstream scheduler
      race (see "The rare connection-leak race and its mitigation")
- [ ] Request body access from `Handler`/`Middleware` (router/App layer)
      — not implemented, see "Middleware & Context"
- [ ] `ServerConfig` wired into the running server (`workers`/`timeout`/
      `maxBodySize` currently do nothing) — see "Config"
- [ ] TLS/HTTPS — put a reverse proxy in front for TLS termination; this
      project has no TLS support of its own
- [ ] Multipart/form-data parsing, WebSockets, HTTP/2, rate limiting

## Limitations

A consolidated list of every gap documented above, for anyone deciding
whether this is production-ready for their use case:

- **No way to read a request body from a router `Handler`.** The
  `App`/`Middleware`/`Context` layer — the actual framework surface most
  code would use — has no combinator for consuming `Context.request.body`.
  Only the low-level `Responder` driver can. A JSON API that needs to read
  a POST body cannot be built with the router today.
- **`ServerConfig` is disconnected from the server.** `workers`,
  `timeout`, and `maxBodySize` are real, env-loadable fields that do
  nothing — the real limits (`MaxHeaderSize`/`MaxContentSize`) are
  hardcoded constants, and worker count comes from `runServerArgs`'s CLI
  arg, not `ServerConfig`.
- **A throughput cliff beyond 2 async worker threads**, caused by an
  unfixed fiber-pinning bug in the underlying `idris2-async` scheduler.
  Stay at the default (2) unless you've benchmarked your own workload
  past it.
- **A rare, not-root-caused connection-leak race** in the same upstream
  scheduler. Mitigated (bounded to roughly one idle-timeout window, not
  eliminated) via `idleTimeout`, not fixed.
- **Unexplained memory growth under sustained load**, independent of the
  above leak (reproduced with zero leaked connections). Leading
  hypothesis is Chez's GC not returning committed pages to the OS, not
  confirmed as bounded over long (hours-scale) runs.
- **Graceful shutdown doesn't work on macOS** — crashes on SIGINT/SIGTERM
  due to a missing syscall in the dependency stack's Darwin support.
  Linux-only in practice.
- **Health checks are fake by default.** `registerStandardChecks` always
  reports healthy; nothing checks a real database, cache, or system
  resource unless you write your own `HealthCheck`s.
- **Sessions are not secure or durable.** Guessable IDs (a process-local
  counter, no CSPRNG available in this stack), no expiry, no GC, no
  persistence across restarts.
- **No TLS.** Terminate TLS in a reverse proxy; this project speaks
  plain HTTP only.
- **No CI.** `pack build`/`flux-test` are run locally, not automated on
  push/PR.
- **The JSON parser is not hardened.** No depth limit, not fuzz-tested,
  and numbers are `Double` (no distinct integer type, so large integers
  lose precision the same way `JSON.parse` in JavaScript does).
- **No multipart/form-data, WebSockets, HTTP/2, or rate limiting.**
  None of these exist in any form yet.
