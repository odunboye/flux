# Flux application platform — Idris clients for Iris

A **separate package** on top of Flux, not a replacement for Flux, Flux DB, or
postgres. The client target is **Idris 2 / Iris**, not Dart or Flutter.
This remains an experimental protocol/client integration milestone, not a
complete application platform or a production-ready release.

## One schema, shared Idris types

`generate.py` produces four files from a versioned schema:

| File | Consumer | Purpose |
| --- | --- | --- |
| `ProtocolTypes.idr` | Server and Iris client | Shared records and object JSON codecs; depends only on json-simple |
| `Protocol.idr` | Flux server | Typed implementation record, POST routes and OPTIONS preflight handlers |
| `Client.idr` | Iris application | Typed endpoint functions returning `Cmd msg` |
| `openapi.json` | API tooling | OpenAPI 3.1 description |

The client package `flux-client` depends on **iris and json-simple**,
not Flux's server runtime, Flux DB or PostgreSQL. Browser builds do not pull
server sockets, worker threads or database bindings into their generated JS.
The distinct server package `flux-protocol` supplies typed endpoint adapters.

### Iris consumption

```idris
import Client
import Flux.Platform.Client.Web

data Msg = TodoCreated (Either RpcError TodoResponse)

-- Return this command from init/update; Iris owns execution/cancellation.
covering
create : String -> Cmd Msg
create title =
  createTodo (webClient "https://api.example.com" (MkFetchOptions 10000 65536))
             (MkCreateTodoRequest title) TodoCreated
```

For a same-origin browser application, use an empty base URL. Native Iris
applications use `nativeClient base` from `Flux.Platform.Client.Native` instead.
Both clients use the same generated endpoint functions and wire types.

- Web/Capacitor: `Iris.Effect.Http.Web.requestWith`, retaining `CancellableTask`
  and its abort action; timeout/size options come from Iris's `FetchOptions`.
- Native: in-process libcurl `Task`, with 5s connect/30s total deadlines, a 64KiB
  response cap and mandatory peer verification. No argv credentials, temporary
  request files, redirects, ambient proxies, netrc or cookie store. HTTPS is
  required except loopback development; `nativeClientWithCA` accepts a PEM CA file.
- Custom transport: supply `MkClient base transport`, where the transport
  produces a Iris `Cmd` from an HTTP request and result-to-message callback.

`RpcError` distinguishes `TransportFailure HttpError`,
`RemoteError status code message`, and `InvalidResponse message`. Malformed
response bodies are not copied into public decoder diagnostics. Credentials,
URL trust and transport selection remain application responsibilities. Use
`withBearer token client` for an immutable session client; portable
`Flux.Platform.Client.Auth` supplies register/login/logout commands. Never persist
bearers in browser storage or put them in URLs. Native Tasks are synchronous and
bounded, not immediately cancellable background workers. These are libcurl
network timeouts, not hard real-time preemption of platform DNS/trust operations.
No application request worker is detached on timeout. The legacy generic
`Iris.Effect.Http` shell transport is still unsuitable for credentials.
Iris Web currently reads response
text before its post-read size check when no usable Content-Length is supplied.

When changing `client/c/http.c`, refresh `platform/flux-client.ipkg`'s timestamp
before `pack --no-prompt install flux-client`: pack otherwise ignores C-only
changes. The combined workspace gate performs this native refresh automatically.

## Protocol scope and server behavior

The generator supports string/bool fields, references to named models,
`{"list": TYPE}` collections and `{"nullable": TYPE}` values. Every declared
field is required: a nullable field accepts explicit JSON null, not an omitted
key. Model dependencies are emitted in deterministic topological order;
recursive models, nested nullable-of-nullable types and overly deep wrapper
nesting are rejected. Requests/responses remain named objects and endpoints
are public or authenticated POST methods under `/rpc/v1/`. IDs are decimal
strings to preserve PostgreSQL BIGINT values exactly across JS targets.
Single-field records always use JSON objects, never newtype unwrapping.
Unknown object fields are ignored for additive compatibility; missing/wrongly
typed required fields fail decoding. Domain validation belongs in callbacks.

Unsupported types, duplicate declarations/JSON keys, invalid identifiers,
unknown models, unsupported versions and unknown access modes fail before
output is written. Generation is schema-first; automatic extraction from
arbitrary Idris types is not implemented.

`access: "authenticated"` generates a `Principal -> Request -> AppProg Response`
callback and requires `routes : Authenticator -> Api -> Router Handler`.
`Authenticator` resolves a credential from the HTTP request to `Maybe Principal`;
`Nothing` returns 401 before JSON parsing or invoking domain code. Store failures
remain redacted errors, never a public-route fallback. Principals are server-only
and never decoded from request JSON. OpenAPI declares bearer security for protected
routes; public routes retain an explicit empty security requirement. Duplicate
Authorization headers are rejected at the HTTP parser boundary.

This adapter is an **enforcement contract**. The new server-only
[`flux-auth`](../packages/auth/README.md) package supplies durable Argon2id accounts
and revocable bearer sessions, and the CRUD app mounts its account routes.
The CRUD starter protects all six task methods and scopes every SQL statement
and pagination lookahead to the verified principal. Other applications must
provide their own row authorization; the legacy Todo/API smoke examples remain
public test fixtures. The
`auth-boundary/` executable uses fixed **test-only** credentials to verify the
contract over real HTTP. Never deploy that fixture. See
[the identity implementation plan](../design/IDENTITY_IMPLEMENTATION.md).

`Flux.Platform.Endpoint.rpcHandler` requires JSON and bounds request bodies to
64 KiB. Install `rpcErrorRenderer` on the enclosing App for typed, redacted
error envelopes. Applications choose CORS policy; generated OPTIONS handlers
supply preflight status but do not choose allowed origins. The public examples
use `useAlways corsAllowAll` so both successes and errors are browser-readable.
Do not adopt wildcard CORS as an authenticated application's policy by default.

`example/Main.idr` is a nonpersistent protocol smoke server.
`example/PGMain.idr` uses the real todo-api pooled repository through Flux DB;
it does not change the existing todo-api entry point or routes.

### Complete typed CRUD example

`crud/schema.json` generates create/get/list/update/toggle/delete Iris methods.
`crud/Main.idr` supplies the domain callbacks using the same pooled repository.
Get/update/toggle return a nullable todo for absent IDs; delete returns a
boolean. IDs must be canonical positive BIGINT decimal strings. Titles written
through these endpoints must contain 1–128 characters. External database writes
can bypass that policy; client response-size limits still apply.

`listTodos` uses a required nullable `afterId` cursor. Pages contain at most 50
records ordered by ID; `nextId` is the last returned ID when more rows exist,
otherwise null. This is keyset pagination, not a cross-request snapshot: writes
between page requests can change what is observed.

The CRUD server bootstraps through Flux DB's migration runner using **frozen,
reviewed SQL**, not an evolving model-derived CREATE statement. Restarts verify
history without resetting data. This does not supply automatic model-to-SQL
migration planning. The CRUD server adds durable account/session APIs through
Flux Auth as migration 2. Migration 3 preserves anonymous rows in
`todos_anonymous_archive` and creates owner-constrained `private_todos`, without
changing migrations 1/2 or adopting old rows. There is no archive HTTP endpoint.
See [the reviewed ownership cutover](crud/OWNERSHIP_MIGRATION.md).

## Build and generate

From the consolidated Flux repository root (Flux/UI/Flux DB/PG sources are included
under `packages/`; no sibling repositories are required):

```sh
python3 platform/generate.py platform/example/schema.json --out platform/example
python3 platform/generate.py platform/example/schema.json --out platform/example --check
python3 platform/generate.py platform/crud/schema.json --out platform/crud
python3 platform/generate.py platform/crud/schema.json --out platform/crud --check
cd platform
pack --no-prompt build example/example.ipkg
pack --no-prompt build example/pg-example.ipkg
pack --no-prompt build example/migrations.ipkg
pack --no-prompt build example/client-native-test.ipkg
pack --no-prompt --cg javascript build example/client-web-test.ipkg
pack --no-prompt build crud/server.ipkg
pack --no-prompt --cg javascript build crud/client-test.ipkg
```

Build/install Iris with the native backend before building JS clients (the
native client build above does this). If Iris sources changed afterwards, run
`pack --no-prompt install iris` first: Iris's packaged demo is native and cannot
be rebuilt with the JavaScript backend.

There is no Dart generator, Dart client, or Dart toolchain dependency.

## Verification

Requires Python 3, pack/Idris2, Node.js with fetch, libcurl 7.85+ development
headers/pkg-config (plus OpenSSL 3 and libsodium for the server), and
Playwright/Chromium installed from this repo's own root `package-lock.json`
(`npm ci` at the repo root, then install Chromium from there). The PG test also
requires Docker with a local `postgres:16` image. From the Flux root:

```sh
python3 -m unittest discover -s platform -p test_generator.py -v
python3 platform/test_wire.py
python3 platform/test_pg_wire.py
python3 platform/test_crud.py
python3 platform/test_app.py
```

`test_wire.py` runs the same generated Idris client on native Chez/curl,
JS/Node fetch, and **real Chromium**. It checks Unicode, large text IDs,
malformed requests/responses, typed transport/domain errors, server-error
redaction and clean shutdown. The Web tests verify command cancellation and
actual cross-origin browser preflight/error handling. The test dispatcher is
minimal; these are HTTP/Cmd integration tests, not a complete Iris test.

`test_pg_wire.py` creates its **own disposable PostgreSQL container**, runs
14 Flux DB migration checks, then runs JS and Chromium generated-client checks.
Each target creates one round-trip row plus 24 concurrent fetch commands. The
runner independently confirms **50 persisted rows** in PostgreSQL and clean
shutdown, then removes only its own container/volume. IDs deliberately exceed
JavaScript's exact integer range. No application database is reset.

`test_crud.py` uses a separate disposable DB. Node and Chromium each run 24
concurrent seven-request CRUD lifecycles. It also checks nullable/nested-list
codecs, missing rows, invalid IDs/titles/cursors, two-page traversal over 55
seed rows, independent DB verification, migration bootstrap and restart safety.
Neither test touches existing application data.

`test_app.py` additionally creates and builds an application in a fresh source
copy through `./flux`, then operates the actual Iris DOM UI against PostgreSQL.
See the [application and CLI guide](crud/README.md) for operation, coverage and
explicit development-only limitations.

Full CRUD regression reports are in `reports/crud/`; the first Idris/Iris
slice is recorded in `reports/iris-client/`. Earlier Dart-based
prototype records are archived under `reports/pre-iris/` and are **not evidence
for this client implementation**.

## Remaining platform work

- Production HTTPS/deployment, backup/restore and distributed anti-abuse.
  Private tasks, session-generation-safe login UI, verified native RPC transport,
  authenticated PostgreSQL TLS and revocable accounts/sessions are implemented;
  MFA, recovery and other identity-provider features are not.
- Enums, optional/omittable fields and additional scalar types.
- Migration planning and integration into the existing todo-api entry point.
  The new CRUD example uses versioned bootstrap; the older one-method PG smoke
  example still creates its table directly.
- Standalone CLI/SDK packaging, watch/reload, deployment, platform observability,
  durable jobs and realtime. The initial repository-local application CLI and
  complete generated-client todo UI are now implemented.

See [the implementation plan](../design/PLATFORM_IMPLEMENTATION.md).
