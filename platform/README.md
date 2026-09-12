# Flux application platform — Idris clients for Iris

A **separate package** on top of Flux, not a replacement for Flux, Nebula, or
idris2-pg. The client target is **Idris 2 / Iris**, not Dart or Flutter.
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

The client package `flux-platform-client` depends on **iris and json-simple**,
not Flux's server runtime, Nebula or PostgreSQL. Browser builds do not pull
server sockets, worker threads or database bindings into their generated JS.
The distinct server package `flux-platform` supplies typed endpoint adapters.

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
- Native: `Iris.Effect.Http.request`, retaining Iris's curl-backed `Task`.
- Custom transport: supply `MkClient base transport`, where the transport
  produces an Iris `Cmd` from an HTTP request and result-to-message callback.

`RpcError` distinguishes `TransportFailure HttpError`,
`RemoteError status code message`, and `InvalidResponse message`. Malformed
response bodies are not copied into public decoder diagnostics. Credentials,
URL trust and transport behavior remain application/Iris responsibilities;
this layer does not introduce an authentication system or stronger transport
limits than Iris supplies. In particular, Iris Web currently reads response
text before its post-read size check when no usable Content-Length is supplied.

## Protocol scope and server behavior

The generator supports string/bool fields, references to named models,
`{"list": TYPE}` collections and `{"nullable": TYPE}` values. Every declared
field is required: a nullable field accepts explicit JSON null, not an omitted
key. Model dependencies are emitted in deterministic topological order;
recursive models, nested nullable-of-nullable types and overly deep wrapper
nesting are rejected. Requests/responses remain named objects and endpoints
are public POST methods under `/rpc/v1/`. IDs are decimal
strings to preserve PostgreSQL BIGINT values exactly across JS targets.
Single-field records always use JSON objects, never newtype unwrapping.
Unknown object fields are ignored for additive compatibility; missing/wrongly
typed required fields fail decoding. Domain validation belongs in callbacks.

Unsupported types, duplicate declarations/JSON keys, invalid identifiers,
unknown models, unsupported versions and authenticated endpoints fail before
output is written. Authentication is deliberately rejected rather than
silently generating a public route for a protected endpoint. Generation is
schema-first; automatic extraction from arbitrary Idris types is not implemented.

`Flux.Platform.Endpoint.rpcHandler` requires JSON and bounds request bodies to
64 KiB. Install `rpcErrorRenderer` on the enclosing App for typed, redacted
error envelopes. Applications choose CORS policy; generated OPTIONS handlers
supply preflight status but do not choose allowed origins. The public examples
use `useAlways corsAllowAll` so both successes and errors are browser-readable.
Do not adopt wildcard CORS as an authenticated application's policy by default.

`example/Main.idr` is a nonpersistent protocol smoke server.
`example/PGMain.idr` uses the real todo-api pooled repository through Nebula;
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

The CRUD server bootstraps through Nebula's migration runner using **frozen,
reviewed SQL**, not an evolving model-derived CREATE statement. Restarts verify
history without resetting data. This does not supply automatic model-to-SQL
migration planning or authentication. Both examples remain public development
applications.

## Build and generate

From the Flux repository root (workspace sibling Iris/Nebula/PG sources required):

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

Requires Python 3, pack/Idris2, Node.js with fetch, native curl, and Iris's
installed Playwright/Chromium development dependencies. The PG test also
requires Docker with a local `postgres:16` image. From the Flux root:

```sh
python3 -m unittest discover -s platform -p test_generator.py -v
python3 platform/test_wire.py
python3 platform/test_pg_wire.py
python3 platform/test_crud.py
```

`test_wire.py` runs the same generated Idris client on native Chez/curl,
JS/Node fetch, and **real Chromium**. It checks Unicode, large text IDs,
malformed requests/responses, typed transport/domain errors, server-error
redaction and clean shutdown. The Web tests verify command cancellation and
actual cross-origin browser preflight/error handling. The test dispatcher is
minimal; these are HTTP/Cmd integration tests, not a complete Iris UI test.

`test_pg_wire.py` creates its **own disposable PostgreSQL container**, runs
14 Nebula migration checks, then runs JS and Chromium generated-client checks.
Each target creates one round-trip row plus 24 concurrent fetch commands. The
runner independently confirms **50 persisted rows** in PostgreSQL and clean
shutdown, then removes only its own container/volume. IDs deliberately exceed
JavaScript's exact integer range. No application database is reset.

`test_crud.py` uses a separate disposable DB. Node and Chromium each run 24
concurrent seven-request CRUD lifecycles. It also checks nullable/nested-list
codecs, missing rows, invalid IDs/titles/cursors, two-page traversal over 55
seed rows, independent DB verification, migration bootstrap and restart safety.
Neither test touches existing application data.

Full CRUD regression reports are in `reports/crud/`; the first Idris/Iris
slice is recorded in `reports/iris-client/`. Earlier Dart-based
prototype records are archived under `reports/pre-iris/` and are **not evidence
for this client implementation**.

## Remaining platform work

- Authenticated PostgreSQL TLS: the underlying existing gap remains.
- User identity/authorization, credential storage and row ownership.
- Enums, optional/omittable fields, additional scalar types and a complete Iris UI.
- Migration CLI/planning and integration into the existing todo-api entry point.
  The new CRUD example uses versioned bootstrap; the older one-method PG smoke
  example still creates its table directly.
- Project CLI, deployment, platform observability, durable jobs and realtime.

See [the implementation plan](../design/PLATFORM_IMPLEMENTATION.md).
