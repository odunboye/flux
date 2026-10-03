# Flux — full-stack Idris applications

**Platform preview.** Flux brings its HTTP server and owned runtime, Flux UI,
Flux DB persistence/migrations, PostgreSQL transport/pooling, and generated Flux UI
clients into one modular repository. The UI now uses the `flux-ui` package and
`Flux.UI.*` modules. Persistence is now `flux-db` / `flux-db-flux` with
`Flux.DB.*` modules. Both are breaking renames without compatibility aliases.
Existing databases must follow the [Flux DB metadata cutover guide](packages/db/MIGRATION.md).
Runtime, protocol/client and Docker packages are now `flux-runtime`,
`flux-protocol`, `flux-client` and `flux-docker`. See the
[coordinated package migration](design/PACKAGE_MIGRATION.md); suitable module
namespaces remain unchanged. PostgreSQL transport/pooling (`postgres`/
`postgres-async`) is no longer vendored here - it moved back to its own
repo, [odunboye/postgres](https://github.com/odunboye/postgres), so it
isn't Flux-only; `pack.toml` pulls it as a pinned external dependency (see
`workspace.json`'s `external_packages`). This is not a production-readiness
declaration.

- `packages/runtime/`: owned tasks, sockets, streams and supervision.
- `packages/ui/`: Flux UI widgets, application lifecycle and platform backends.
- `packages/db/`, `packages/db-flux/`: persistence and PG integration, built on the external `postgres`.
- `platform/`: shared protocols, generated server/client code and typed CRUD examples.
- `examples/todo-api/`: database-backed application example.
- `website/`: Flux's landing page, served by Flux itself.

See the [workspace/package map](design/CONSOLIDATION.md) and
[typed Flux UI client guide](platform/README.md). No sibling repositories or
user-specific dependency paths are needed. Run `python3 tools/workspace.py check`
to verify the package map and browser/server dependency boundary.

For the combined integration gate, first install the prerequisites in the
[workspace guide](design/CONSOLIDATION.md), then run:

```sh
python3 tools/workspace.py test
```

## Run the landing page

```sh
pack --no-prompt build website/landing.ipkg
(cd website && ./build/exec/flux-landing 8080 128)
```

Open **http://127.0.0.1:8080**. See the [site guide](website/README.md)
for the design, server configuration and browser verification.

## Learn Flux by use case

The [examples guide](examples/README.md) walks through public HTTP APIs, typed
JSON, middleware/health, generated contracts, PostgreSQL migrations, private
accounts/tasks, Idris UI effects and native clients. Start with the small runnable
recipes in `examples/src/Recipes/`, then follow the complete application.

## Run the Flux UI application

```sh
./flux doctor
./flux build
./flux dev --watch --disposable-db --no-build
# Open http://127.0.0.1:8090
```

`--watch` refreshes CSS without resetting UI state, rebuilds changed Idris targets,
and reloads browsers after successful publication. Failed builds leave the previous
application running and show compiler diagnostics. See the
[live-reload guide](design/DEV_RELOAD.md) for configuration and limitations.
`--hot` additionally supports [model-preserving DOM replacement](design/DEV_HMR.md)
for applications opting into `runWebHot` with a versioned state codec.

This creates a disposable PostgreSQL database and removes it on exit. For
persistent data, configure `PG*` explicitly and omit `--disposable-db`.
The [application/CLI guide](platform/crud/README.md) covers `new`, `generate`,
`check`, `build`, `migrate`, `dev` and native `run`, plus real browser/database acceptance tests.
The starter has private, owner-scoped tasks and an Idris registration/login UI.
It is a local multi-user preview, not a production-readiness promise; deployable
HTTPS, operations and backup/restore remain separate work.

## External applications and native run

The same CLI works outside this repository; no application-specific launcher is
needed. Install this checkout's command with `./flux install-cli`, ensure its bin
directory is on PATH, then:

```sh
cd /path/to/application
flux sync
flux generate
flux check
flux build
flux dev --hot --disposable-db
flux run --disposable-db
```

Format-2 `flux.json` declares source/public layout, namespaces, local dependencies
and native asset integration. `run` launches a verified built native web server,
not the development proxy. Existing format-1 examples still work with `dev`.
See the [application CLI guide](design/APPLICATION_CLI.md) for migration, explicit
project selection, installer collision handling and database/artifact ownership.

## HTTP server reference

The existing `flux` package remains an HTTP/1.1 framework using `flux-runtime`.
Request parsing, persistent connections, streaming responses, routing and
middleware are implemented in Idris; a small native shim provides readiness
and standalone shutdown supervision. The sections below document this server
package, not every component of the full-stack preview.

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
static file serving. Every path segment is percent-decoded once, upfront
(`matchPath`), before either `Literal` or `:name` matching sees it — a
request for `/users/John%20Doe` binds `id` to `"John Doe"`, not the raw
`"John%20Doe"` (previously not decoded at all — every path-param/splat-
consuming handler was affected). `matchRoute` returns a 3-way
`MatchResult` (`Matched`/`WrongMethod`/`NoMatch`) so a genuine 405 (with
a correct `Allow` header, listing every method some route in the table
would have accepted for that path) is distinguishable from a 404 — most
minimal routers collapse those into one case.

Matching is a linear scan of the route list on every request — fine for
the size of route table a typical app has, but there's no trie/radix
optimization, so a very large route table pays O(routes) per request.

A `HEAD` request falls back to a matching `get` route if no route was
registered specifically for `HEAD` (RFC 9110 §9.3.2 — a `HEAD` response
is defined identically to what `GET` would produce, just without a body,
and `Flux.Core.Middleware.render` already suppresses the body correctly
for any `HEAD` request regardless of which route actually matched).
Register a route via `head_` explicitly to override this with
custom `HEAD`-specific behavior — an exact `HEAD` match always wins over
the `GET` fallback. `Allow` (on a 405) lists `HEAD` wherever `GET` is
allowed for the same reason, even for a wrong-method request that wasn't
itself `HEAD`.

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
(`{"error":"..."}`). If the discarded `Context` was holding a resource
(a `Streamed` body wrapping an open file descriptor, say - see "Static
files") in that window between a handler succeeding and `after` running,
`runApp` drains it first, rather than letting the reset silently orphan
it unpulled.

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
- `workers` — the active connection limit (labeled "connections"
  in the startup log line) - a different knob from `FLUX_EVENT_LOOPS`
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

`renderSetCookie` strips `;`/`\r`/`\n` from a cookie's name, value, and
path before rendering, and `Flux.Core.Middleware.setHeader` strips
`\r`/`\n` from any header value — a raw incoming request header can
never carry one of these through in the first place (the wire parser
splits on `\r\n` before values are extracted), but a handler building a
cookie/header value from other data (an echoed value, an upstream API
response) previously could inject a stray `;`-attribute or an entire
extra header line into its own response. Silently stripped rather than
rejected, so `setHeader`/`cookie` stay plain, non-fallible functions.

Response header names must be nonempty ASCII HTTP tokens, as defined by
[RFC 9110 sections 5.1 and 5.6.2](https://www.rfc-editor.org/rfc/rfc9110.html#section-5.6.2).
`validHeaderName` exposes this check. `setHeader`/`setHeaders` ignore invalid
names without trimming or repairing them. At the final wire boundary,
`encodeResponse` also omits entries with malformed names or ASCII control
characters in values (HTAB is permitted). This protects direct encoder calls,
`ok`, cookie output and direct updates to the public `Context` record. Existing
`setHeader` CR/LF stripping is retained; direct encoder calls omit the entire
malformed entry. Valid header case, ordering and repeated fields are preserved.
These checks establish field syntax safety, not field-specific semantics; the
application still owns the meaning of a valid header.

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
a DB) for either of those. Separately, the platform now provides
[`flux-auth`](packages/auth/README.md): PostgreSQL-backed password accounts and
revocable bearer sessions that survive restarts. It does not change this cookie
middleware or automatically make existing public endpoints private.

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

That reused `Fd` is only released when the `Streamed` response it's
wrapped in actually runs to completion - `resource`/`bracket`'s cleanup
fires as part of pulling the stream, not on construction. Two distinct
paths used to let a `Context` holding one go unpulled, both fixed:

- A response whose body gets suppressed (a HEAD request, or status
  204/304 - see "Errors") used to never touch that stream at all, so
  the fd leaked on every one; `render` now drains a suppressed
  `Streamed` body (discarding its bytes, never sending them)
  specifically so this cleanup still runs. Confirmed via `lsof` against
  a real running server: 15 HEAD requests to the same file leaked 15
  fds before this fix, 0 after.
- `staticHandler` succeeding (fd opened, `Context` built) doesn't mean
  that `Context` reaches `render` at all - something *later* in the
  same request (an `after` hook, say) can still throw, and `runApp`
  resets to a fresh `Context` on any error (see "Middleware & Context"),
  discarding the resource-holding one entirely without ever pulling it.
  `runApp` now drains that specific case too (the `Context` right after
  dispatch, before `after` runs) before letting the error reset
  proceed. Confirmed the same way: a standalone reproduction (a route
  wrapping `staticHandler`, with an `after` hook that always throws)
  leaked one fd per request before this fix, zero after.

`root` is a relative path resolved against the *process's* working
directory, not the source file's or executable's location - run the
example server from anywhere other than `examples/` (e.g. the repo
root) and `"public"` silently resolves to a directory that doesn't
exist, so every static request 404s. See "Install / build" above.

## Concurrency and ownership

Flux now uses `flux-runtime`; its dependency graph no longer includes
`async`, `async-posix`, `streams`, or `streams-posix`. `FLUX_EVENT_LOOPS`
selects the number of connection owner threads and defaults to 2. Accepted
connections are assigned round robin. A connection's tasks and continuations
remain on its owner; unrelated connections can run on other owners.

The `workers` server setting is the maximum number of active connections,
not the number of OS threads. Blocking operations belong on the runtime's
bounded worker pool. `Flux.DB.PG.dbIO` uses that pool, and `Flux.DB.Pool` supplies
exclusive database leases. Sharing one raw `DB` across requests is unsafe.

Handler signatures such as `Async Poll es a` remain compatibility aliases
for the new `Task es a`; no old scheduler is involved. Low-level socket and
supervisor APIs changed. Use `Flux.Async.Server.serve` for embedded servers
and explicit stop tasks. See the [runtime guide](packages/runtime/README.md).

## Graceful shutdown

The standalone `runProg`/`runProgWith` runner owns SIGINT/SIGTERM handling.
On a signal the server stops accepting connections, allows 30 seconds for
existing connections to finish, then cancels stragglers. Resource cleanup
joins task children and native work before closing their resources.

An independent native watchdog exits with status 124 if shutdown still has
not completed after 35 seconds. It does not depend on a responsive Idris
owner loop. Embedded runtime APIs never force process exit. Background tasks
passed to `runProgWith` are canceled and joined when the program ends.

Cancellation cannot safely kill arbitrary synchronous IO. Use deadline-aware
transports and scoped resources. Old scheduler benchmarks and failure
investigations do not describe this runtime; measure this implementation
with your workload. `test/runtime_soak.py` exercises 1, 2, and 4 owner loops
and records request counts, resident memory, and shutdown outcomes.

## Errors

Handler/middleware code sees `AppError` (`throw (MkAppError status msg)`,
caught and rendered via `App.onError`) and `Errno` (any lower-level IO
failure, also caught and rendered as a generic 500 rather than dropping
the connection). Wire-level parsing errors (`HTTPErr`: malformed request
line, oversized headers, oversized content-length) are handled entirely
inside the driver (`Flux.Core.HTTP`) below the `App`/`Handler` layer —
app code never sees them; a malformed request just gets a bare 400.

That includes request-framing rejections RFC 9112 §5.1/§6.3 requires,
closing off request-smuggling shapes behind a proxy that disagrees with
this parser about where a request ends: whitespace between a header
name and its colon (`Content-Length : 5`, `Content-Length\t: 5`) - a
parser that doesn't reject this can end up storing the header under a
different key than the canonical one (`"content-length "` with a
trailing space, say), so the *real* Content-Length silently goes
unrecognized by both this exact check and `contentLength`'s own lookup;
a repeated `Content-Length` header (a plain map-insert would silently
keep the last one instead of rejecting the conflict); any
`Transfer-Encoding` at all (chunked request bodies aren't decoded here -
treating one as an ordinary, length-less request would parse it as
empty and misinterpret the chunked-framed bytes that follow as the next
pipelined request); and a `Content-Length` value that isn't a plain run
of digits (previously cast silently to `0` instead of failing).

A declared `Content-Length` larger than what the client actually sends
is also rejected (`TruncatedBody`), not silently accepted as a complete
body once the connection runs dry - the underlying stream library's own
`splitAt` can't tell "got exactly n bytes" apart from "the source had
fewer than n and ran out" (both just return an already-finished
continuation), so this parser can't rely on it alone; a small wrapper
(`splitAtChecked`) checked lazily, in the same place, throws instead.

An `HTTP/1.1` request with no `Host` header is rejected (RFC 9112 §3.2
makes it mandatory there; `HTTP/1.0` predates `Host`, so it's optional
on a `1.0` request). A repeated `Host` header is rejected outright too,
the same shape as the repeated-`Content-Length` case above - a real
cache-poisoning/routing-confusion vector if silently accepted, since
whichever `Host` a downstream proxy trusts may disagree with whichever
one this parser would otherwise have kept.

Any of these rejections closes the connection outright (a bare 400, then
EOF) rather than attempting to resume parsing a pipelined request that
might follow the malformed one on the same connection - the safest
possible answer once the parser and the client have disagreed about
where a request ends, and how `Flux.Core.HTTP.echoWith` has always
behaved.

Response framing is enforced the same way regardless of what a
`Handler` does: a response to a HEAD request or with status 204/304
never carries a body (204/304 carry no framing header at all; HEAD
still carries the one a GET would have, just no body bytes), and
`render` always owns `Content-Length`/`Transfer-Encoding` itself - a
`Handler` that sets one directly via `setHeader` doesn't produce a
duplicate on the wire. A suppressed `Streamed` body (HEAD/204/304) is
still drained, not just left untouched - `Flux.Middleware.Static`'s
open file descriptor is only released when its stream actually runs to
completion (see "Static files"), so never running it at all on a
suppressed response would leak it.

## Running the tests

```sh
pack build test/test.ipkg
./test/build/exec/flux-test
```

206 tests across 11 suites (router, HTTP wire parsing, HTTP wire parsing
*properties*, JSON, middleware, logging, config, cookies, sessions,
static files, health) — mostly pure/unit-style with no real socket or
database involved, though a handful (the `runApp` error-catching tests,
`readBody`'s success/failure/keep-alive tests in `TestMiddleware.idr`,
the `Connection`-header/`willClose` tests in the same file, and
`TestHTTPProperties.idr`'s `request` round-trip and pipelining-desync
tests) do run the real `Async`/`Pull` scheduler end to end against a
synthetic in-memory body/request, rather than simulating it. Nothing
here goes over an actual TCP connection.

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
- [x] Real `Connection`-header semantics (RFC 9112 §9.3): `HTTP/1.1`
      defaults persistent unless the client sends `Connection: close`;
      `HTTP/1.0` defaults closing unless it sends `Connection:
      keep-alive` — honored both in what the server actually does and in
      what the response's own `Connection` header reports back, which
      also correctly reflects an unrelated forced close (a `readBody`
      failure) the client's own header said nothing about — see "Errors"
- [x] `Host` header required on `HTTP/1.1` (RFC 9112 §3.2), a repeated
      one rejected — see "Errors"
- [x] GET/POST/HEAD/PUT/DELETE/PATCH/OPTIONS, path params (`:id`) and
      splat params (`*path`), query strings; `HEAD` falls back to a
      matching `get` route (RFC 9110 §9.3.2) unless a `head_` route
      overrides it — see "Routing"
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
- [x] Graceful shutdown on SIGINT/SIGTERM, on both Linux and macOS, with
      a bounded drain (30s) so a connection stuck forever can't block
      exit indefinitely — see "Graceful shutdown"
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
- **A throughput cliff beyond 1 async worker thread**, caused by an
  unfixed fiber-pinning bug in the underlying `idris2-async` scheduler.
  A fix exists and its throughput improvement is confirmed, but it's
  blocked on a separate, not-yet-root-caused cancelation-stall bug of
  its own - see "Concurrency: async worker threads". Stay at the
  default (1) unless you've benchmarked your own workload past it.
- **A rare, not-root-caused connection-leak race** in the same upstream
  scheduler. Mitigated in two layers - bounded to roughly one
  idle-timeout window via `idleTimeout`, and shutdown specifically
  additionally bounded via `serveConnections`'s `drainTimeout` so a
  connection stuck this way can't block `SIGTERM` past 30s - not
  eliminated either way; see "The rare connection-leak race and its
  mitigation".
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
- **The cookie middleware remains in-memory.** Its IDs have expiry and GC,
  but no restart persistence. Use the separate `flux-auth` platform package for
  durable PostgreSQL-backed password accounts and revocable bearer sessions.
  The starter now includes private task ownership and a session-safe login UI.
  Production deployment and broader identity-provider features remain future work.
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
- **Static-file symlink defense has a narrow residual TOCTOU window** -
  the containment check and the real `openFile` are still two separate
  syscalls; see "Static files" for what that does and doesn't cover.
