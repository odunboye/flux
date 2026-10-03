# Application platform implementation plan

Status: in progress. The runtime checkpoint is complete; the application
platform is a separate, substantially larger project. Do not describe plans,
generated scaffolding, or an isolated endpoint as Serverpod feature parity.

Source consolidation is now implemented as a modular Flux repository. See
[the workspace/package map](CONSOLIDATION.md) for locations, preserved history,
current package IDs and the combined verification command. Flux UI now uses
`flux-ui` and `Flux.UI.*` in an outright breaking rename; see
[the migration guide](../packages/ui/MIGRATION.md).

## Boundaries

- Flux: transport, request lifecycle, routing, middleware, supervision.
- postgres: PostgreSQL protocol, connection safety, transport security, pool.
- Flux DB: persistence models, queries, repositories, migrations.
- Platform package: protocol contracts, typed adapters, generated clients,
  configuration, CLI and integration. Initially incubated in `platform/` as
  a separate package depending on Flux; Flux must not depend on it.

## Shared contracts / first vertical slice

Start schema-first with an explicitly versioned JSON intermediate protocol.
Generate shared Idris wire records, typed Flux route adapters, an Idris client
returning Flux UI `Cmd msg` values, and OpenAPI from that same description.
The client target is Flux UI, not Dart/Flutter. The portable client package depends
on Flux/UI/json-simple only; it must not import the Flux server runtime or PG. This deliberately avoids pretending
that arbitrary dependent Idris types can cross a network. Idris elaborator
metadata extraction can later target the identical intermediate protocol.

Current subset: required string/bool fields, named model references, lists and
explicitly nullable fields; named object requests/responses and POST endpoints
with a bounded JSON body. Omittable fields and recursive models are unsupported. IDs are decimal strings, not JSON
numbers, so Flux UI's JavaScript targets do not lose PostgreSQL BIGINT precision. Domain
validation remains in server application code. Generated codecs validate
untrusted input; they do not establish domain invariants.

Errors use a stable `error.code` plus a safe `error.message`. Internal database
or transport details must not become public responses. Initial endpoints are
explicitly public. Authenticated generation now requires a server authenticator
and passes only its resolved principal into protected callbacks. There is no
public fallback. Durable password accounts and revocable sessions are now supplied
by `flux-auth`; owner-scoped repositories remain pending. See `IDENTITY_IMPLEMENTATION.md`.

## Implemented first increment

- `platform/flux-protocol.ipkg`: independent package with bounded typed public
  endpoint adapters and stable, redacted RPC error envelopes.
- Deterministic schema generator: shared Idris object codecs, Flux API/routes,
  Flux UI client and OpenAPI 3.1; drift checks and fail-closed unsupported features.
- Flux UI native and Web transport adapters preserving Task/CancellableTask shapes.
- Real HTTP client tests on Chez/curl, Node/fetch and Chromium, including Unicode,
  string BIGINTs, malformed input, typed errors, redaction, cancellation and CORS.
- Real pooled todo repository integration: Node and Chromium each execute a
  24-command concurrent batch plus one round-trip call; 50 persisted rows
  independently confirmed in PostgreSQL, followed by clean shutdown.
- Flux DB `DB.Migration`: reviewed forward-only SQL subset, dedicated
  connection/session advisory lock, version/name/checksum history verification,
  and per-migration transactional application/history insertion.
- The original checkpoint passed 14 migration integration checks. The Flux DB
  rename expands this to 21, including metadata cutover and pre-execution SQL
  batch rejection. See [the migration guide](../packages/db/MIGRATION.md).
  Companion Flux DB commit: `a177aee8d3370fd970ff262e549a3611ae3778d2`.

The first Flux/UI/client checkpoint is Flux `f64aef7`, paired with the Flux DB
commit above.

## Implemented second increment

- Generator supports acyclic named-model dependencies, list values and explicit
  nullability, with deterministic topological output and matching OpenAPI.
- `platform/crud/`: complete generated create/get/list/update/toggle/delete Flux UI
  methods backed by the pooled todo repository.
- Canonical BIGINT ID validation, bounded titles and 50-row keyset pagination.
- Versioned migration bootstrap with frozen SQL and safe restart verification.
- 18 generator tests; Node and Chromium each pass 24 concurrent seven-request
  CRUD lifecycles, nullable/list decoding, invalid request and pagination tests.
- Independent PostgreSQL checks verify seed preservation, history and restart;
  earlier wire/PG/migration tests and Flux regressions pass again.

That increment used public POST methods. Subsequent checkpoints added the complete
Flux UI/CLI, durable accounts/sessions, then protected owner-scoped task methods,
a session-safe login UI and hardened in-process native RPC transport. Recursive
models, omittable fields and a production deployment workflow remain future work.
Legacy todo-api entry points are unchanged; a separate public PG smoke example
exercises those repositories. Authenticated PG TLS uses OpenSSL 3.

## Flux UI application and project CLI checkpoint

- `platform/crud/TodoUI.idr`: complete generated-client CRUD UI, keyset pages,
  explicit loading/empty/validation/error states, edit/delete cancellation,
  write serialization, lifecycle cancellation recovery without automatic write
  replay, and reload persistence. IDs remain strings.
- `./flux`: repository-local `new/doctor/generate/build/migrate/dev`, reviewed
  starter registration in the canonical map, strict project configuration,
  loopback static/RPC development serving and explicit disposable DB ownership.
- Fresh-source acceptance creates/builds a new app, applies migrations twice,
  exercises real Chromium UI flows and independently checks PostgreSQL.
- Root CI's combined gate includes CLI unit tests and actual application
  acceptance, not only raw generated-client commands.

This is an initial macOS/Linux workspace CLI, not a published standalone SDK,
watch/reload service, automatic migration planner or deployment system. The
[application guide](../platform/crud/README.md) records operation and limitations.

## Workstreams and integration gates

| Track | Next implementation | Completion gate |
| --- | --- | --- |
| Protocol/client | Full typed CRUD and todo UI implemented; next: additional wire types and transport hardening | Broader protocol contracts and UI scenarios |
| Persistence | Explicit SQL runner and CRUD example bootstrap implemented; migration application CLI implemented; next: model-to-SQL planning and existing app integration | Repeatable fresh install and upgrade through the application workflow |
| Identity/security | Authenticated PG TLS; session/identity contract; endpoint and row ownership authorization | Trusted cert accepted; unknown CA/hostname/expiry rejected; cross-user access denied |
| Developer tooling | Initial workspace CLI/template and disposable services implemented; next: standalone packaging, watch/reload and deployment | Fresh checkout through generate/build/test/deploy with no user-specific paths |
| Operations | Request IDs, structured logging/metrics, pool wait metrics, readiness, deployment | Diagnose injected DB failures; CI and shutdown/restart tests |
| Services | Durable jobs, realtime, uploads, email, caching | Each service has bounded resource use, recovery and authorization tests |

The first five tracks can progress independently after contracts settle, but
must meet at the same example application. Durable jobs and realtime depend
on identity, persistence and lifecycle contracts and must not be implemented
as unowned background work merely to mark a checklist complete.

## Security decisions needing implementation

Authenticated PostgreSQL TLS is implemented using OpenSSL 3 with mandatory chain
and SAN hostname/IP verification, explicit/system trust, and the existing owned
deadline transport. The integration gate tests certificate rejection and real
PostgreSQL TLS/SCRAM, cancellation and timeout cleanup. See the driver README.
Durable accounts, revocable sessions and protected endpoint enforcement are now
implemented separately in `flux-auth`. The starter now has owner-scoped SQL,
a reviewed anonymous-data archive migration and session-generation-safe login UI.
Native RPC uses in-process verified libcurl. Production deployment remains pending;
legacy `examples/todo-api` and protocol smoke fixtures remain public test examples.
Hosted Linux CI confirmation remains separate from local macOS/Linux-container evidence.

Never auto-apply destructive migration changes. Migration commands must target
an explicit environment, and tests must use disposable databases. Never
recycle database persistence models indiscriminately as public API records
(password hashes, tokens and internal fields must not leak into generated clients).

## Verification policy

Keep generation deterministic and reject unsupported schemas before writing
any output. Compile generated Idris for native and JS targets, and test Flux UI
commands in real browser/native HTTP environments. Test the
wire contract against a running server rather than only comparing generated
text. Preserve existing runtime and application regressions. Do not commit
unrelated security reports or benchmarks. A final completion report must list
actual tests, skipped capabilities, unresolved security gaps and commit IDs.
