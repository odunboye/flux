# Flux by use case

Start with a small HTTP service, then move to generated contracts, persistence
and a private Idris UI. These examples use features implemented in this repository;
there are no placeholder job queues, realtime services or deployment promises.
Run commands from the **repository root** unless stated otherwise.

## Choose an example

| What you want to build | Start here | What it demonstrates |
| --- | --- | --- |
| A greeting/localization API | [Recipes/Greetings.idr](src/Recipes/Greetings.idr) | Routes, path/query parameters, JSON and validation |
| A quote/calculation endpoint | [Recipes/Quotes.idr](src/Recipes/Quotes.idr) | Derived JSON codecs, bounded input, integer arithmetic, typed errors |
| A small observable service | [Recipes/Main.idr](src/Recipes/Main.idr) | Composition, request IDs, security headers, timing, environment configuration and health routes |
| A larger HTTP API/static site | [Existing HTTP demo](src/Main.idr), [landing app](../website/README.md) | CRUD verbs, static assets, middleware, cookies and a real Flux-served website |
| A schema-first service with Idris clients | [Protocol example](../platform/example/schema.json) | Generated server adapters, clients, nullable/list models and OpenAPI |
| A database-backed application | [Private Todo server](../platform/crud/Main.idr) | PostgreSQL pools, parameterized SQL, reviewed migrations, keyset pagination |
| A private multi-user application | [Todo application guide](../platform/crud/README.md) | Durable accounts, revocable sessions and principal-derived row ownership |
| An interactive Idris frontend | [TodoUI.idr](../platform/crud/TodoUI.idr) | Model/update/view, commands, lifecycle handling and stale-response protection |
| Native authenticated RPC | [Native client](../platform/client/src/Flux/Platform/Client/Native.idr) | In-process verified TLS transport; no credential argv/body files |

The stateless recipes below are deliberately public. The private starter is a
separate application; adding a login screen does not protect a public handler.

## 1. Public API: path parameters and localization

Build and run the focused recipes (no database or browser tooling required):

```sh
pack --no-prompt build examples/use-cases.ipkg
FLUX_SERVER_PORT=8092 ./examples/build/exec/flux-use-cases
```

In another terminal:

```sh
curl -i 'http://127.0.0.1:8092/hello/Ada'
# {"message":"Hello, Ada!"}
curl -i 'http://127.0.0.1:8092/hello/Ada?language=es'
# {"message":"Hola, Ada!"}
curl -i 'http://127.0.0.1:8092/hello/Ada?language=unknown'
# HTTP 400, JSON error, and an X-Request-ID header
```

`getParam` reads the router's path parameters, while `getQuery` reads a query
parameter. The handler returns `sendJSON` on success and throws `MkAppError` for
invalid input. The application chooses `jsonErrorRenderer` once instead of every
handler constructing its own error envelope.

## 2. Typed JSON: compute a quote without floating-point money

Use the same running server:

```sh
curl -i http://127.0.0.1:8092/quotes \
  -H 'Content-Type: application/json' \
  --data '{"quantity":3,"unitPriceCents":1250}'
# {"quantity":3,"totalCents":3750}

curl -i http://127.0.0.1:8092/quotes \
  -H 'Content-Type: application/json' \
  --data '{"quantity":0,"unitPriceCents":1250}'
# HTTP 400: domain validation rejects zero quantity
```

[Quotes.idr](src/Recipes/Quotes.idr) derives `FromJSON`/`ToJSON`, requires JSON
content type, and caps the request body at 2 KiB. Integer cents avoid binary
floating-point rounding; bounded quantities/prices keep output within JavaScript's
exact integer range. Wrong content type returns 415; malformed, missing, oversized
or out-of-range input returns 400. `requireJsonBody`'s oversized-body error is 400,
not 413.

**Not a checkout/payment implementation:** nothing is stored or charged. Real
checkout must obtain authoritative prices from server-side inventory, not trust a
customer-supplied price, and needs explicit currency/tax/idempotency rules.

## 3. Service composition: middleware, health and configuration

```sh
curl -i http://127.0.0.1:8092/health
curl -i http://127.0.0.1:8092/ready
curl -i http://127.0.0.1:8092/live
curl -i http://127.0.0.1:8092/startup
```

[Recipes/Main.idr](src/Recipes/Main.idr) composes both handlers into one router.
`useAlways` ensures request IDs and security headers survive error responses.
`timing` plus `responseTime` adds timing to successful responses. No wildcard CORS
is enabled. `serverConfigFromEnv` reads `FLUX_SERVER_*` settings; the default host
is loopback. Ctrl-C/SIGTERM uses the runtime's owned shutdown/draining path.

The health registry is **empty because this service is stateless**. These checks
do not prove PostgreSQL readiness. A database application must register a real
check for its dependencies. Do not log Authorization headers, passwords or bodies
when extending observability. This is not a production HTTPS deployment recipe.

## 4. Contract-first RPC: share types, not handwritten wire formats

Explore [schema.json](../platform/example/schema.json), its generated
[Protocol.idr](../platform/example/Protocol.idr) server adapter and
[Client.idr](../platform/example/Client.idr) Idris client:

```sh
python3 platform/generate.py platform/example/schema.json --out platform/example --check
pack --no-prompt build platform/example/example.ipkg
```

Edit the schema, then omit `--check` to regenerate. Implement the generated API
callbacks in application code; generated files should not be hand-edited.
OpenAPI is emitted beside the Idris code. Nullable fields require their key with
explicit `null`; they are not omittable fields. BIGINT identifiers use decimal
strings so browser clients preserve every digit.

For executable transport examples, see
[ClientNativeTest.idr](../platform/example/ClientNativeTest.idr) and
[ClientWebTest.idr](../platform/example/ClientWebTest.idr), and the
[platform build/test instructions](../platform/README.md). The protocol smoke
example is public and nonpersistent, not an authenticated application template.

## 5. Persistence: pooled SQL, reviewed upgrades and pagination

[The private Todo server](../platform/crud/Main.idr) is the complete runnable
example rather than an in-memory repository disguised as persistence:

- `withConnectionIO` borrows a PostgreSQL connection for a scoped operation.
- SQL parameters carry user data; string concatenation does not build queries.
- Migrations are forward-only, reviewed and checksummed. Do not change an applied
  migration to match a new model; append a migration.
- Lists fetch at most 51 rows: 50 results plus a lookahead row to determine
  `nextId`. Both the query and lookahead include the owner predicate.
- IDs stay strings on the wire. Pagination is not a cross-request snapshot.
- Storage failures are redacted; PG exception detail can contain private data.

Read the [ownership migration guide](../platform/crud/OWNERSHIP_MIGRATION.md)
before upgrading populated data. Anonymous rows are archived, not assigned to the
first account that registers. For remote PostgreSQL, configure
`PGSSLMODE=verify-full`, optionally `PGSSLROOTCERT`; see the
[PostgreSQL TLS guide](../packages/postgres/README.md). HTTP HTTPS and PG TLS are
separate connections and require separate configuration.

## 6. Private application: register, log in and keep tasks isolated

```sh
./flux doctor
./flux new task-board
./flux --project apps/task-board build
./flux --project apps/task-board dev --disposable-db --no-build
# Open http://127.0.0.1:8090 in two independent browser profiles/contexts.
```

Register different accounts in each browser, sign in, and create different tasks.
Each account should see only its own tasks. Sign out and sign in as the other
account: the old account's rows and draft disappear. Reload requires sign-in again.

**Disposable data is removed on successful shutdown.** For persistence, load
`PGHOST`, `PGPORT`, `PGUSER`, `PGPASSWORD` and `PGDATABASE` through your local secret
configuration, then omit `--disposable-db`. Do not commit secrets or expose this
development proxy publicly. `new` refuses an existing destination; choose another
name if `apps/task-board` already exists.

Follow the implementation across these boundaries:

1. [Flux Auth](../packages/auth/README.md): Argon2id accounts, opaque digest-only
   sessions, expiry, logout, logout-all and password-change revocation.
2. [Authenticated schema](../platform/crud/schema.json): every task callback
   receives a server `Principal` resolved before request-body decoding.
3. [Owner-scoped SQL](../platform/crud/Main.idr): get/update/toggle/delete constrain
   **owner and ID in the same statement**. A foreign ID behaves like a missing ID.
4. [Idris UI](../platform/crud/TodoUI.idr): passwords are masked/cleared, bearers
   remain in memory, and every async result carries a session generation.

The existing HTTP demo's `/visits` cookie counter is a different feature: it is
process-local visitor state, **not durable account authentication**. Its in-memory
user ID allocation is also demo-only and must not be copied as a database sequence.

## 7. UI effects and native clients: handle uncertainty explicitly

`TodoUI.idr` demonstrates generated `Cmd` effects rather than JavaScript business
logic. Busy state prevents duplicate submissions. A lifecycle interruption can
cancel a request **after its write committed**, so the UI asks for a refresh and
never automatically replays the write. Logout clears private state immediately;
unconfirmed server revocation requires an explicit retry. Expiry/revocation clears
the model when an API request returns 401, not via an idle expiry timer.

For another UI example without the database application, see
[the standalone Flux UI Todo](../packages/ui/examples/todo/).

Use `webClient` for browser/Capacitor fetch and `nativeClient` (or
`nativeClientWithCA`) for native RPC. After login, `withBearer session.token client`
constructs an immutable per-session client. Portable
[`Flux.Platform.Client.Auth`](../platform/client/src/Flux/Platform/Client/Auth.idr)
supplies register/login/logout commands. A complete, compiled native account/task
flow is in [NativeAuthTest.idr](../platform/crud/NativeAuthTest.idr); its literal
credentials are **test fixtures**, not defaults for an application.

Native RPC uses in-process libcurl, verified HTTPS outside loopback, bounded
responses and network timeouts. Native Tasks are synchronous, not immediately
cancellable background workers. Do **not** use the legacy generic
`Flux.UI.Effect.Http` shell transport for credentials, and never put tokens in
URLs, command arguments or browser storage.

## Verify the examples

```sh
# Focused stateless examples: builds and real HTTP assertions.
pack --no-prompt build examples/use-cases.ipkg
python3 examples/test_use_cases.py

# Entire workspace: includes real PostgreSQL, generated/native clients and UI.
# Requires Docker plus browser tooling installed as described in the app guide.
python3 tools/workspace.py test
```

The focused checks cover successful requests, malformed input, domain/body limits,
error-path middleware, health endpoints and owned shutdown. The full gate also
checks two-user SQL/browser isolation, migrations, revocation, stale callbacks,
native transport safety and disposable cleanup. Production deployment, managed
jobs/realtime, email/recovery and automatic migration planning remain separate work.
