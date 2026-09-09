# flux

An HTTP/1.1 server framework for Idris2, built from scratch on top of
[`idris2-streams`](https://github.com/stefan-hoeck/idris2-streams)'
`async`/`streams-posix` — no C server library, no FFI to an existing web
server. The wire protocol (request parsing, persistent connections,
chunked transfer-encoding), the router, and the middleware/`Context`
pipeline are all implemented directly in this repo; JSON (see "JSON"
below) is the one thing layered on top that isn't - everything else
built on top (cookies, sessions, static files, health checks) is.

## Project goals

The goal is a **usable, honestly-documented** framework: routing,
middleware, JSON, cookies/sessions, static files, structured error
handling and streaming responses all work and are tested (146 unit tests,
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

The example server. Run it from `examples/`, not the repo root -
`staticHandler`'s `"public"` root (see "Static files" below) is resolved
relative to the process's working directory, and `examples/public/` only
exists there:

```sh
pack build examples/examples.ipkg
cd examples
./build/exec/flux-examples 8080 128   # port, worker count
# or, config-driven (see "Config" below):
FLUX_SERVER_PORT=8080 ./build/exec/flux-examples --from-env
```

## Usage

```idris
import Flux

%language ElabReflection

record User where
  constructor MkUser
  id   : Integer
  name : String

%runElab derive "User" [ToJSON]

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
`defaultErrorRenderer` (plain text) and `Flux.Middleware.JSON.jsonErrorRenderer`
(`{"error":"..."}`).

Neither `before` nor `after` run at all on that error path - a request
that throws never reaches `after` (so e.g. access logging never runs for
it), and loses whatever `before` had already set (CORS/security headers,
a request ID). `useAlways` registers a third kind of hook that runs
regardless - on the successful path (after `after`) and on the
error-rendered path alike - for anything a response should never be
missing: `examples/src/Main.idr`'s `buildApp` registers
`corsAllowAll`/`secureHeaders`/`reqId`/`requestAccessLog` this way. Plain
`use`/`useAfter` keep their original meaning (success path only) -
`useAlways` is the opt-in escape hatch, not a change to what they mean.

Responses are either fully buffered (`send`/`sendText`/`sendJSON`) or
streamed (`sendStream (Just len) body` for a known length, `sendStream
Nothing body` to chunk-transfer-encode a body of unknown length —
`Flux.Core.HTTP.chunkEncode` implements RFC 7230 chunked framing directly).
`Flux.Middleware.Static.staticHandler` is built on `sendStream`, so a
static file is streamed off disk (`readBytes`), not buffered in memory
before it's sent.

**Reading a request body**: `readBody maxBytes ctx` (`Flux.Core.Middleware`)
collects up to `maxBytes` from `Context.request.body` and returns
`Either BodyError ByteString` — `Left BodyTooLarge`/`BodyMalformed`/
`BodyIOError`, or `Right bytes`. A **successful** read keeps the
connection alive for further pipelined requests exactly like any other
request; a **failed** one always forces the connection closed after this
response — once a bounded read aborts partway through, there is no
continuation that safely resumes parsing the next request from wherever
the wire position was left (confirmed against the underlying library's
actual combinators, not assumed). This is why `readBody` reports its
result as a plain value rather than `throw`ing an `AppError`: `runApp`
resets to a fresh `Context` on any caught error (see above), which would
silently lose "the body was read" for exactly the case that matters — a
`Handler` that reads the body successfully and *then* throws for an
unrelated reason must still keep the connection alive, not lose that to
the reset. See `examples/src/Main.idr`'s `createUser` handler for a
worked example (JSON-decoding a POST body), and `Flux.Core.HTTP`'s
`BodyOutcome`/`respondWith` for how the driver actually enforces this at
the wire level.

## JSON

Flux used to have its own small, dependency-free `JSON` value type and
hand-written recursive-descent parser/encoder. That parser was badly
broken for anything beyond a bare scalar - multi-key objects and
multi-element arrays never parsed past their first entry (nothing
returned the leftover input position after consuming a value), and
every decoded *string* came out reversed (`"Carol"` decoded as
`"loraC"` - the accumulator was built in the correct order, then
reversed again on completion). Neither bug was caught by the original
tests, which only ever decoded bare scalars like `"true"`/`"42.5"`.
Found and fixed while building `readBody` (a JSON-decoding POST handler
was the first thing to actually decode an object) - but even fixed, it
still had no depth limit and wasn't hardened against adversarial input,
being plain, natively-recursive descent.

JSON support is now [`json-simple`](https://github.com/stefan-hoeck/idris2-json)
(the `JSON.Simple`/`JSON.Simple.Derive` modules), built on `ilex-json` (a
real DFA-based lexer) - both from the same author as the rest of this
project's dependency stack. This is a strict upgrade on every front that
mattered: elaborator-derived `ToJSON`/`FromJSON` instances
(`%runElab derive "User" [ToJSON]` instead of hand-writing one - see
`examples/src/Main.idr`'s `User`/`NewUser`) instead of hand-written ones,
`JInteger`/`JDouble` instead of one `Double` silently losing integer
precision, real `\uXXXX` Unicode escape handling, and - the specific
hardening gap this was about - a stack-based (not natively-recursive)
parser, confirmed directly (not assumed) to parse a 100,000-level-deep
nested array without crashing, before any of this was wired in. The
tradeoff: `ilex-json`/`elab-util` are now real dependencies - "small,
dependency-free JSON" is no longer accurate, and wasn't worth clinging
to once the alternative was this much more correct.

`Flux.Middleware.JSON` is what's left in Flux's own namespace: just the
glue tying `json-simple`'s `ToJSON`/`encode` to `Context`/`ErrorRenderer`
(`sendJSON`, `sendJSONError`, `jsonErrorRenderer`, `jsonResponse`/
`jsonError` for outside the router, `isJSON`) - import `JSON.Simple`
directly for the `JSON` type/interfaces themselves, the same as any
other `json-simple` user would. `test/src/TestJSON.idr` tests only this
glue now (JSON encode/decode correctness is `json-simple`'s own concern,
and its own test suite's job, not re-tested here).

## Config

`Flux.Server.Config` can build a `Config` from environment variables with
a given prefix (`loadFromEnv "FLUX_"`: `FLUX_SERVER_PORT=9090` becomes key
`"server.port"`) and parse a `ServerConfig`/`AppInfo` out of it.

`Flux.Core.HTTP.runServerFromConfig : Responder -> ServerConfig -> Prog
[Errno] Void` is a `ServerConfig`-driven alternative to `runServerArgs`,
wiring every field to something real:

- `host` — parsed via `parseIPv4` (a small dotted-quad-only parser Flux
  wrote itself; nothing in the dependency tree provides one) into the
  actual bind address, so e.g. `FLUX_SERVER_HOST=0.0.0.0` really does
  bind all interfaces, not just loopback. An unparseable host warns to
  stderr and falls back to `127.0.0.1` rather than crashing.
- `workers` — the `foreachPar` accept-loop concurrency (labeled "workers"
  in the startup log line) - a different knob from `IDRIS2_ASYNC_THREADS`
  (see "Concurrency" below), which this doesn't touch.
- `maxBodySize` — replaces the hardcoded `MaxContentSize` (~4GB) as the
  ceiling `assemble` rejects an oversized Content-Length against.
  `MaxHeaderSize` (64KB) is **not** configurable either way - `ServerConfig`
  has no field for it, so it stays fixed regardless of which entry point
  is used.
- `timeout` (milliseconds) — replaces the hardcoded `idleConnectionTimeout`
  (60s) - see "Concurrency" below for what this actually bounds.

`runServer`/`runServerArgs` are unchanged (still hardcoded to `127.0.0.1`
and the constants above via `defaultLimits`) - `runServerFromConfig` is
additive, not a replacement. `defaultServerConfig`'s `workers`/`timeout`
were deliberately set to match `runServerArgs`'s own defaults (128
workers, 60s) once they started doing something, so adopting
`runServerFromConfig` with no env vars set is behavior-neutral rather
than a silent regression; `maxBodySize`'s default (1MB) is a deliberate
exception - a real cap being worth having, now that the field does
something, even though it's far tighter than `runServer`'s effectively
unlimited default. `Config` itself is fully functional as a generic
env-var-backed key/value store independent of any of this (`test/src/TestConfig.idr`).

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
`IO CheckResult` checks (`addCheck`/`emptyRegistry`). `/ready` sets a
real `503` when unhealthy, not just `"status":"not ready"` in an
otherwise-200 body - `sendJSON` alone never touches the status code, so
a status-code-based readiness checker (the normal kind, e.g.
Kubernetes) needs that explicitly.

There used to be five bundled "standard" checks, all hardcoded
placeholders that unconditionally reported `Healthy` regardless of
anything real — worse than no health checks at all for anything that
actually trusts the result (an orchestrator's liveness/readiness probe,
say). `databaseCheck`/`cacheCheck`/`externalServiceCheck` are gone
outright: what "healthy" means for a specific database or cache
connection is application-specific, and Flux has no database/cache
client of its own to check generically — write your own, it's just
`HealthCheck = IO CheckResult`. `diskCheck` is gone too, for a
different reason: a real implementation exists in principle
(`statvfs`, POSIX, both platforms) via this project's own dependency
tree, but as shipped there every `Statvfs`/`FileStats` field accessor
is linked against the wrong library — calling it fails at runtime with
a missing-symbol error on both platforms as currently shipped upstream
— and working around that means reimplementing the struct-marshaling
FFI code from scratch (real memory-safety risk if gotten wrong), not
attempted here.

`memoryCheck (thresholdMB : Integer) : IO CheckResult` **is real**: it
reads the process's own RSS from `/proc/self/status` — the same plain
file-IO approach `Flux.Middleware.Internal.Random` uses for
`/dev/urandom`, no FFI. Linux-only (`/proc` doesn't exist on Darwin) —
reports `Degraded`, never a false `Healthy`, anywhere it can't get a
real answer, whether that's the platform or an unexpected
`/proc/self/status` format. `mkHealthStatus`'s `timestamp` field is
also now a real Unix timestamp (`System.Clock`), not the hardcoded `0`
it used to be.

## Cookies & sessions

`Flux.Middleware.Cookies` parses the `Cookie` request header and renders
`Set-Cookie` (`cookie` gives sane defaults: root path, `HttpOnly`,
session-lifetime, not `Secure` — set `{ secure := True }` explicitly for
TLS). `Flux.Middleware.Session` builds an in-memory, cookie-backed session
store on top of it, sharded 16 ways the same way request IDs are (see
"Concurrency" below).

Session IDs are 128 bits of real OS entropy, hex-encoded — not a
guessable counter. `Flux.Middleware.Internal.Random` reads directly from
`/dev/urandom` via `System.Posix.File` (already used the same way for
regular files by `Flux.Middleware.Static`): Idris2's own `System.Random`
turned out not to be suitable here (traced to Chez's plain `random`/JS's
`Math.random()` — non-cryptographic, not OS-entropy-seeded per call),
and nothing else in the dependency tree exposes a labeled CSPRNG, but
`/dev/urandom` needed no new C code — the existing POSIX file wrapper
has no restriction to regular files and no Darwin-specific gap.

Sessions now expire after a configurable idle period
(`newSessionStore`'s `ttlMs` — `session` treats an expired cookie
exactly like no cookie at all, issuing a fresh id) and a background
sweep, `sessionGCLoop` (raced alongside the server the same way as
`accessFlushLoop` — see `examples/src/Main.idr`), actually reclaims
expired entries so a long-running server doesn't accumulate them
forever. What's still explicitly out of scope: persistence across
restarts and sharing sessions across more than one process — this
remains in-memory and single-process; swap in a real backend (Redis,
a DB) for either of those.

## Static files

`Flux.Middleware.Static.staticHandler root mimeFor`, mounted under a
splat route (`get "/static/*path" (staticHandler "public" defaultMimeFor)
router`). Guards against path traversal two ways: lexically (rejects
`..` segments and a leading `/` in the resolved relative path — tested,
`test/src/TestStatic.idr`) and against a symlink *inside* `root`
pointing back outside it (both `root` and the resolved request path are
canonicalized before a containment check; rejected with 403). Resolution
is namei()-style: a single worklist of pending path segments, checking
whether the accumulated path is a symlink after *every* segment push -
whether that segment came from the original path or was just spliced in
from a symlink target a moment ago - following any chain it finds
(bounded to 40 symlink dereferences, matching Linux's own `MAXSYMLINKS`)
with proper `..`/`.` handling relative to the link's own directory. This
one-segment-at-a-time discipline matters: an earlier version of this
check bulk-substituted a discovered symlink's whole target before a
single check of the result, which missed an *intermediate* symlink
introduced by a multi-segment target (e.g. `a -> b/c` where `b` is
itself a symlink pointing outside `root`) - a real, confirmed bypass,
fixed by unifying both cases into the one worklist; see
`test/src/TestStatic.idr`'s `testRejectsIndirectSymlinkEscape` for the
regression test. There's exactly one `openFile` call: the same `Fd`
used to confirm the file exists (so a missing file still gets a clean
404 instead of failing mid-stream, past the point a status code can
still be chosen) is reused directly for the actual stream, rather than
closed and reopened by path — the latter would be a real TOCTOU window
between the check and the stream. This isn't airtight — the
containment check and the real `openFile` are still two separate
syscalls, the same residual gap most `realpath`-based checks have too
(closing it fully needs kernel support this dependency stack doesn't
have, e.g. Linux 5.6+'s `openat2`/`RESOLVE_NO_SYMLINKS`) — it defends
against a symlink placed once by whoever populates the served
directory, not an attacker who can also race the filesystem underneath
a live request. `defaultMimeFor` covers common web/text/image types,
falling back to `application/octet-stream`.

`root` is a relative path resolved against the *process's* working
directory, not the source file's or executable's location - run the
example server from anywhere other than `examples/` (e.g. the repo
root) and `"public"` silently resolves to a directory that doesn't
exist, so every static request 404s. See "Install / build" above.

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

**Issue.** A server-side connection occasionally never gets closed after
the peer sends FIN - the socket is left sitting in `CLOSE_WAIT` and the
fd is never released. This is a bug in stock upstream `idris2-async`
itself (reproduces on unmodified `stefan-hoeck/idris2-async`), not
something Flux or this fork introduced, and it's independent of the
thread-count/fiber-pinning issue above - it happens even at
`IDRIS2_ASYNC_THREADS=1`.

**Effect.** Left alone, leaked fds/sockets accumulate under sustained
load without bound - a real resource-exhaustion risk for a long-lived
process. It's also why the round-robin scheduling fix mentioned above
had to be reverted: that fix (plus a self-pipe change it depended on)
made this pre-existing leak reproduce far more often, blocking the
throughput-cliff fix from shipping until this is understood.

**Mitigation (shipped).** `serveWith` wraps every connection in
`idleTimeout` (`Flux.Core.HTTP`), a watchdog fiber that cancels a
connection if a shared "activity" counter hasn't moved in
`idleConnectionTimeout` (default 60s). Bounded testing (back-to-back
`wrk` runs against one long-lived process) confirms this works: leaked
fds/`CLOSE_WAIT` sockets accumulate under load but get reaped within
roughly one to two timeout windows, dropping to zero once load stops,
rather than growing without bound. Set it lower if you need a tighter
bound and can accept more false positives against genuinely slow (but
not stuck) clients - via `ServerConfig.timeout` through
`runServerFromConfig` (see "Config" above), or the hardcoded
`idleConnectionTimeout` constant for `runServer`/`runServerArgs`. This
is a mitigation, not a fix - the underlying race is still there.

**Root-cause investigation, so far (not fixed - findings only):**

- **The key repro lever**: the posix backend runs one dedicated poller
  thread that does nothing but loop `poll()` on a fixed timeout
  (10ms by default). Shortening that timeout to 1ms takes the leak from
  reproducing on roughly 1 in 20 runs of a trivial `wrk -t1 -c2 -d1s`
  load to reproducing on essentially every run. The trigger is `poll()`
  *responsiveness* (how soon it reacts to fd-state changes), not the
  round-robin dispatch change itself - a bisection of the reverted fix
  showed the leak reproduces from a faster poll loop alone, with no
  round-robin or self-pipe change present at all. Round-robin dispatch
  was very likely a red herring for this specific bug (it's still the
  real, separate cause of the throughput cliff above), bundled into the
  same reverted commit only because it needed the self-pipe change as a
  co-requisite.
- **Ruled out by direct instrumentation**: `Poller.idr`'s `insrt`
  silently calls `cleanup` instead of retrying on a CAS-insert failure -
  a plausible-looking way to silently drop a registration. Instrumented
  and tested against the fast (1ms) repro: a leak reproduced, but this
  branch never fired. Not the mechanism.
- **Ruled out, mostly**: that connection cleanup (`RFD`'s `Resource`
  release in `idris2-streams`, a raw `close()`) bypasses the scheduler's
  own cancellation-to-registration-cleanup wiring. `IO.Async.Loop.idr`'s
  `observeCancel` does correctly invoke the `pollFile` cancel hook
  before a canceled fiber unwinds into resource release, for the
  ordinary case (fiber canceled while suspended in `poll`, not inside a
  masked/uncancelable region). Two narrower variants of this - whether
  *normal* (non-cancellation) stream completion retires a registration
  the same way, and whether cancellation inside a masked region skips it
  - remain unconfirmed either way.
- **Confirmed directly** (not inferred): instrumenting
  `Flux.Core.HTTP.serveWith`'s entry and its `guarantee` cleanup action,
  tagged by fd number, caught the actual failure live. For one fd,
  reused three times in a 15s repro run as short connections cycled
  through it, the log read `ENTER fd=5`, `CLOSE fd=5`, `ENTER fd=5`,
  `CLOSE fd=5`, `ENTER fd=5` - no matching third `CLOSE`. `lsof` on the
  live process at that moment confirmed fd 5 was the exact socket
  sitting in `CLOSE_WAIT`. So the leaked connection's fiber never reaches
  *any* of `guaranteeCase`'s terminal branches (success/error/cancel) at
  all - it's parked forever, not mis-cleaned-up. `guarantee`'s cleanup
  wiring itself is not the bug.
- **Leading hypothesis, not yet confirmed**: `Poller.idr`'s
  `pollWaitImpl` snapshots `(fd, event)` pairs for the `poll()` syscall
  itself, but when results come back, `handleEvs` re-looks-up the
  handler for that fd from the *live* registration map, not the
  snapshot. Fd numbers get reused fast under load (confirmed - the fd=5
  above cycled through three unrelated connections within 15 seconds).
  There's a plausible window where a `poll()` result meant for an old,
  already-closed connection gets delivered against whatever new
  connection now holds that same fd number by the time results are
  processed - or a stale cleanup evicts a new connection's live
  registration. This is grounded in the code's structure, not yet caught
  in the act; the concrete next step is instrumenting `handleEvs`/
  `getHandle` itself against the same fast repro used above.

### Memory growth under sustained load

Separately from the connection leak, resident memory grows under sustained
load and doesn't fully return to baseline once idle — observed even with
**zero** connection leak present (`IDRIS2_ASYNC_THREADS=1`, `CLOSE_WAIT`/FD
counts flat the whole time). This rules out both an application-level
buffer bug (`BatchedAccessLog`'s flush loop correctly drains its buffer
every tick) and the connection leak as the cause.

Two soak tests (16-24 rounds of 20s `wrk` bursts against `/api/users`,
followed by 4-5 minutes idle, sampling both process RSS and - via a
temporary `bytes-allocated` probe - Chez's own live-heap size) narrowed
down what's actually happening:

- **It is not purely "GC not returning committed pages to the OS."** The
  live heap itself (not just RSS) measurably grows under load - e.g. one
  run's live heap averaged ~29MB across its first 8 rounds and ~37MB
  across its last 8, tracking RSS's growth (though at roughly half the
  proportional rate). A real, if modest, working set is growing under
  load, not just an allocator artifact.
- **It plateaus, at least within the windows tested.** Growth clearly
  decelerates over each run, and in the longer of the two runs (24
  rounds), RSS went fully flat - 12 consecutive samples with zero
  movement - after about 3 minutes idle. The shorter run's 4-minute idle
  window wasn't quite long enough to reach the same clean flatline (RSS
  was still creeping slightly at the end), consistent with "takes a
  couple of minutes to settle," not "never settles."
- **Not confirmed**: behavior over much longer (hours-scale) continuous
  operation. Both soak tests here are ~10-15 minutes; a working set that
  plateaus within 15 minutes could still drift slowly over hours. That
  needs a real long-running soak test, not done here.

## Graceful shutdown

`shutdownOn [SIGINT, SIGTERM]` (wired into `runServer`/`runProgWith`)
stops accepting new connections on either signal while letting in-flight
connections finish (`foreachPar`'s internal semaphore-drain blocks until
they do) — there's no shutdown timeout, so a stuck handler blocks exit
indefinitely.

Works on both Linux and macOS. It used to rely on `async-posix`'s
`awaitSignals`, which calls the POSIX.1b `sigwaitinfo()` syscall — a
syscall the `posix` package's C support explicitly excludes on Darwin,
crashing the server (`Exception in foreign-procedure: no entry for
"li_sigwaitinfo"`) on SIGINT/SIGTERM instead of shutting down cleanly.
`Flux.Core.HTTP.fluxAwaitSignals` replaces it with a small polling loop
over `sigpending()` (plain POSIX.1, available on both platforms, already
exposed portably by the `posix` package) — it only needs to notice that
one of the watched signals has arrived, not decode which one or recover
`Siginfo` detail, so it never touches the Darwin-excluded call at all.
Verified manually on both platforms; there's no unit test for it (not
realistic for OS-signal behavior) — see `examples/src/Main.idr`'s
`/slow` handler for the manual verification steps.

## Errors

Handler/middleware code sees `AppError` (`throw (MkAppError status msg)`,
caught and rendered via `App.onError`) and `Errno` (any lower-level IO
failure, also caught and rendered as a generic 500 rather than dropping
the connection). Wire-level parsing errors (`HTTPErr`: malformed request
line, oversized headers, oversized content-length) are handled entirely
inside the driver (`Flux.Core.HTTP`) below the `App`/`Handler` layer —
app code never sees them; a malformed request just gets a bare 400.

That includes request-framing rejections RFC 9112 §6.3 requires, closing
off a request-smuggling shape behind a proxy that disagrees with this
parser about where a request ends: a repeated `Content-Length` header (a
plain map-insert would silently keep the last one instead of rejecting
the conflict), any `Transfer-Encoding` at all (chunked request bodies
aren't decoded here - treating one as an ordinary, length-less request
would parse it as empty and misinterpret the chunked-framed bytes that
follow as the next pipelined request), and a `Content-Length` value
that isn't a plain run of digits (previously cast silently to `0`
instead of failing). Response framing is enforced the same way
regardless of what a `Handler` does: a response to a HEAD request or
with status 204/304 never carries a body (204/304 carry no framing
header at all; HEAD still carries the one a GET would have, just no
body bytes), and `render` always owns `Content-Length`/`Transfer-Encoding`
itself - a `Handler` that sets one directly via `setHeader` doesn't
produce a duplicate on the wire.

## Running the tests

```sh
pack build test/test.ipkg
./test/build/exec/flux-test
```

146 tests across 11 suites (router, HTTP wire parsing, HTTP wire parsing
*properties*, JSON, middleware, logging, config, cookies, sessions,
static files, health) — mostly pure/unit-style with no real socket or
database involved, though a handful (the `runApp` error-catching tests,
`readBody`'s success/failure/keep-alive tests in `TestMiddleware.idr`,
and `TestHTTPProperties.idr`'s `request` round-trip) do run the real
`Async`/`Pull` scheduler end to end against a synthetic in-memory body/
request, rather than simulating it. Nothing here goes over an actual TCP
connection.

`test/src/TestHTTPProperties.idr` is [`idris2-hedgehog`](https://github.com/stefan-hoeck/idris2-hedgehog)
(property-based testing, QuickCheck-style, with integrated shrinking)
against `Flux.Core.HTTP`'s wire parser (`method`/`version`/`startLine`/
`headers`/`splitQuery`/`parseQuery`/`request`) - added specifically
because that parser is exactly the same shape of hand-rolled, stateful
parsing code as the JSON parser that had three real, compounding bugs
this session (see "JSON"), none of which any hand-picked example ever
caught. It's already paid for itself once: a first, naive "headers
round-trip exactly" property failed within 45 generated cases on a
header value that was pure whitespace (`" "`, parsed back as `""`) - on
inspection, Flux was behaving *correctly* (RFC 7230 strips a header
value's surrounding whitespace, so an all-whitespace value legitimately
becomes empty), but the property's own assumption was too naive. Fixing
it to expect `trim v` instead of `v` is what's in the suite now - a
precise, correct specification the hand-picked examples never had to
state explicitly. One real limitation found building this: hedgehog's
`property`/`forAll` do-block runs in a purely generator-based monad with
no `IO` support at all, so it can't run anything needing the real async
runtime (`request` itself) - worked around for those specific cases via
`Hedgehog.Gen.sample`, drawing random input in plain `IO` and asserting
in an ordinary loop instead, at the cost of hedgehog's automatic
shrinking on a failing case.

`.github/workflows/ci.yml` runs on every push/PR: building `flux.ipkg`
and running `flux-test`, building `examples/examples.ipkg`, and a live
smoke test that starts the actual example server and drives it over a
real HTTP connection (routing, `readBody`, JSON, pagination, 404 vs 405,
static files) - the one thing the unit suite above doesn't cover. Still
not covered by either: live keep-alive/close/host-binding behavior
specifically (the `curl -v`/`wrk` checks used throughout this session)
and anything requiring sustained load (the benchmarking in "Concurrency"
above) - both remain manual.

## Features

- [x] HTTP/1.1 with persistent connections (keep-alive), pipelining-safe
      request framing - duplicate `Content-Length`, `Transfer-Encoding`,
      and a malformed `Content-Length` value are all rejected rather
      than silently resolved (a request-smuggling shape behind a proxy
      that disagrees about where a request ends); response framing
      (HEAD/204/304 body suppression, no duplicate framing headers) is
      enforced by `render` regardless of what a `Handler` does — see
      "Errors"
- [x] GET/POST/HEAD/PUT/DELETE/PATCH/OPTIONS, path params (`:id`) and
      splat params (`*path`), query strings
- [x] Router with proper 404 vs 405 (`Allow` header) distinction
- [x] Middleware pipeline (`before`/`after`), typed `AppError` handling
      caught and rendered without dropping the connection
- [x] Streaming/chunked responses (`sendStream`), used by static file
      serving
- [x] JSON via `json-simple` (derivable `ToJSON`/`FromJSON`), JSON error
      rendering — see "JSON"
- [x] Cookies, in-memory sessions — sharded, real random IDs
      (`/dev/urandom`), expiry + background GC; still single-process,
      not durable across restarts — see "Cookies & sessions"
- [x] Static file serving with path-traversal protection, including
      against a symlink inside the served directory pointing outside it
      — see "Static files"
- [x] Health/liveness/readiness/startup routes; a real `memoryCheck`
      (Linux) — no more fake always-`Healthy` placeholders — see
      "Health checks"
- [x] Env-var config loading (`Config`), wired into the running server
      via `runServerFromConfig` (`host`/`workers`/`maxBodySize`/`timeout`)
      — see "Config"
- [x] Two logging strategies (immediate vs batched/format-on-flush), with
      measured concurrency tradeoffs for each — see "Logging"
- [x] Graceful shutdown on SIGINT/SIGTERM, on both Linux and macOS — see
      "Graceful shutdown"
- [x] An idle-connection timeout mitigating a known upstream scheduler
      race (see "The rare connection-leak race and its mitigation")
- [x] Request body access from a router `Handler` (`readBody`), with a
      real keep-alive-preserving continuation on success — see
      "Middleware & Context"
- [x] CI (`.github/workflows/ci.yml`): builds, unit tests, and one live
      HTTP smoke test on every push/PR — see "Running the tests"
- [x] Property-based tests (`idris2-hedgehog`) against the HTTP wire
      parser — see "Running the tests"
- [ ] TLS/HTTPS — put a reverse proxy in front for TLS termination; this
      project has no TLS support of its own
- [ ] Multipart/form-data parsing, WebSockets, HTTP/2, rate limiting

## Limitations

A consolidated list of every gap documented above, for anyone deciding
whether this is production-ready for their use case:

- **`MaxHeaderSize` (64KB) is still not configurable** through either
  `ServerConfig` (no field for it) or any other entry point - the one
  request-size limit `runServerFromConfig` doesn't let you change.
- **`parseIPv4` only accepts a literal dotted-quad** ("127.0.0.1",
  "0.0.0.0") - no hostnames, no DNS resolution, no IPv6. `ServerConfig.host`
  set to anything else falls back to `127.0.0.1` with a stderr warning.
- **A throughput cliff beyond 2 async worker threads**, caused by an
  unfixed fiber-pinning bug in the underlying `idris2-async` scheduler.
  Stay at the default (2) unless you've benchmarked your own workload
  past it.
- **A rare, not-root-caused connection-leak race** in the same upstream
  scheduler. Mitigated (bounded to roughly one idle-timeout window, not
  eliminated) via `idleTimeout`, not fixed.
- **Memory growth under sustained load**, independent of the above leak
  (reproduced with zero leaked connections) - real (both RSS and Chez's
  own live-heap size grow, not just an allocator artifact), but
  decelerating and plateauing within the ~10-15 minute windows tested;
  not confirmed over hours-scale continuous operation - see "Memory
  growth under sustained load".
- **No disk-space health check.** `diskCheck` was removed rather than
  shipped broken - see "Health checks" for the upstream `statvfs`
  linking bug behind that. `memoryCheck` is real, but Linux-only.
  Database/cache/external-service checks were never something Flux
  could provide generically - write your own via `addCheck`.
- **Sessions are not durable.** IDs are now real random tokens with
  expiry and GC (see "Cookies & sessions") - what's left is
  single-process-only: no persistence across restarts, no sharing across
  a cluster.
- **No TLS.** Terminate TLS in a reverse proxy; this project speaks
  plain HTTP only.
- **CI covers unit tests, both builds, and one live smoke test - not
  everything.** Live keep-alive/close/host-binding behavior and anything
  requiring sustained load (benchmarking) are still manual-only - see
  "Running the tests".
- **New dependencies for JSON.** Swapping Flux's own hand-rolled (and
  buggy) JSON parser for `json-simple`/`ilex-json` (see "JSON") means
  this is no longer a dependency-free part of the framework - a
  deliberate tradeoff, not an oversight.
- **No multipart/form-data, WebSockets, HTTP/2, or rate limiting.**
  None of these exist in any form yet.
- **The router doesn't fall a HEAD request back to a route registered
  with `get`.** Method matching is exact (`Flux.Core.Router.matchRoute`),
  so a HEAD request to a GET-only route gets `WrongMethod`/405, not the
  GET handler with its body suppressed - discovered incidentally while
  fixing `render`'s HEAD body suppression (which is correct and does
  work, once a request actually reaches a handler). No `head` route
  combinator exists yet either. Not fixed here.
- **Static-file symlink defense has a narrow residual TOCTOU window** -
  the containment check and the real `openFile` are still two separate
  syscalls; see "Static files" for what that does and doesn't cover.
