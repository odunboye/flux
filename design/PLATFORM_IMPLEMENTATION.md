# Application platform implementation plan

Status: in progress. The runtime checkpoint is complete; the application
platform is a separate, substantially larger project. Do not describe plans,
generated scaffolding, or an isolated endpoint as Serverpod feature parity.

## Boundaries

- Flux: transport, request lifecycle, routing, middleware, supervision.
- idris2-pg: PostgreSQL protocol, connection safety, transport security, pool.
- Nebula: persistence models, queries, repositories, migrations.
- Platform package: protocol contracts, typed adapters, generated clients,
  configuration, CLI and integration. Initially incubated in `platform/` as
  a separate package depending on Flux; Flux must not depend on it.

## Shared contracts / first vertical slice

Start schema-first with an explicitly versioned JSON intermediate protocol.
Generate shared Idris wire records, typed Flux route adapters, an Idris client
returning Iris `Cmd msg` values, and OpenAPI from that same description.
The client target is Iris, not Dart/Flutter. The portable client package depends
on Iris/json-simple only; it must not import the Flux server runtime or PG. This deliberately avoids pretending
that arbitrary dependent Idris types can cross a network. Idris elaborator
metadata extraction can later target the identical intermediate protocol.

Initial subset: required string/bool fields, named object requests/responses,
POST endpoints with a bounded JSON body. IDs are decimal strings, not JSON
numbers, so Iris's JavaScript targets do not lose PostgreSQL BIGINT precision. Domain
validation remains in server application code. Generated codecs validate
untrusted input; they do not establish domain invariants.

Errors use a stable `error.code` plus a safe `error.message`. Internal database
or transport details must not become public responses. Initial endpoints are
explicitly public. Authenticated endpoints must be rejected by generation
until identity/authorization enforcement is implemented, not silently exposed.

## Implemented first increment

- `platform/flux-platform.ipkg`: independent package with bounded typed public
  endpoint adapters and stable, redacted RPC error envelopes.
- Deterministic schema generator: shared Idris object codecs, Flux API/routes,
  Iris client and OpenAPI 3.1; drift checks and fail-closed unsupported features.
- Iris native and Web transport adapters preserving Task/CancellableTask shapes.
- Real HTTP client tests on Chez/curl, Node/fetch and Chromium, including Unicode,
  string BIGINTs, malformed input, typed errors, redaction, cancellation and CORS.
- Real pooled todo repository integration: Node and Chromium each execute a
  24-command concurrent batch plus one round-trip call; 50 persisted rows
  independently confirmed in PostgreSQL, followed by clean shutdown.
- Nebula `Data.PGMigration`: reviewed forward-only SQL subset, dedicated
  connection/session advisory lock, version/name/checksum history verification,
  and per-migration transactional application/history insertion.
- 14 migration integration checks pass in a disposable PostgreSQL container.
  Companion Nebula commit: `a177aee8d3370fd970ff262e549a3611ae3778d2`.

This is not completion of the platform. The protocol supports only required
string/bool record fields and public POST methods. There is no complete Iris UI,
identity system, migration CLI or deployment workflow. Client transport behavior
and limits are inherited from Iris, not strengthened by these adapters.
Existing todo-api entry points are unchanged; a separate PG example exercises
its repositories. The underlying PG TLS authentication gap remains unresolved.

## Workstreams and integration gates

| Track | Next implementation | Completion gate |
| --- | --- | --- |
| Protocol/client | First generated create call implemented; next: full CRUD, collections/nullability, transport hardening and Iris UI | Complete generated-client application, not just one method |
| Persistence | Explicit SQL runner implemented/tested; next: model-to-SQL planning, CLI, todo bootstrap integration | Repeatable fresh install and upgrade through the application workflow |
| Identity/security | Authenticated PG TLS; session/identity contract; endpoint and row ownership authorization | Trusted cert accepted; unknown CA/hostname/expiry rejected; cross-user access denied |
| Developer tooling | CLI, portable project template, validated configuration, disposable local services | Fresh checkout through generate/build/test/deploy with no user-specific paths |
| Operations | Request IDs, structured logging/metrics, pool wait metrics, readiness, deployment | Diagnose injected DB failures; CI and shutdown/restart tests |
| Services | Durable jobs, realtime, uploads, email, caching | Each service has bounded resource use, recovery and authorization tests |

The first five tracks can progress independently after contracts settle, but
must meet at the same example application. Durable jobs and realtime depend
on identity, persistence and lifecycle contracts and must not be implemented
as unowned background work merely to mark a checklist complete.

## Security decisions needing implementation

The current pure-Idris PG TLS implementation does not verify server identity.
Do not present encrypted-only transport as authenticated TLS. A mature TLS
backend is preferable for a secure production path to inventing an X.509
validator during platform assembly; preserve deadlines, IO ownership and
explicit trust configuration. This needs a dedicated implementation and
negative-path certificate tests, not just documentation or a flag.

Never auto-apply destructive migration changes. Migration commands must target
an explicit environment, and tests must use disposable databases. Never
recycle database persistence models indiscriminately as public API records
(password hashes, tokens and internal fields must not leak into generated clients).

## Verification policy

Keep generation deterministic and reject unsupported schemas before writing
any output. Compile generated Idris for native and JS targets, and test Iris
commands in real browser/native HTTP environments. Test the
wire contract against a running server rather than only comparing generated
text. Preserve existing runtime and application regressions. Do not commit
unrelated security reports or benchmarks. A final completion report must list
actual tests, skipped capabilities, unresolved security gaps and commit IDs.
