# Flux DB / Flux integration

Package: `flux-db-flux` 0.3. Modules: `Flux.DB.PG`, `Flux.DB.Pool`.
This is a breaking rename with no old package or namespace aliases; see
[the migration guide](../db/MIGRATION.md).

Glue lifting [flux-db](../db)/[idris2-pg](../postgres)'s
`IO (Either PGError a)` calls into [Flux](../..) (an
Idris2 HTTP framework)'s `AppProg`/`Handler` pipeline. `Flux.DB.PG` is the module
(`Flux.DB.PG`) that used to live in `flux-db` itself, split out into its
own package so a consumer that only wants `flux-db`'s active-record layer
or typed query builder (no HTTP framework at all) doesn't have to pull
in Flux and its own dependency tree just to get them.

## Why this exists

An app using `flux-db`'s active-record/query-builder layer through Flux
would otherwise hand-write, per project, the handful of lines that turn
idris2-pg's own `IO (Either PGError a)` return shape into a Flux
handler's `AppProg a` - run it, `throw` a `500 AppError` on `Left`. None
of that is app-specific - no schema, no routes, no handlers - so it
belongs in a shared library instead of being re-derived per project.
`todo-api` (`../../apps/todo-api`) is the first real
consumer; this library exists so the second one doesn't re-derive it.

## Usage

```idris
import Flux.DB.PG

getUser : DB -> Handler
getUser db ctx = do
  uid <- requireId ctx
  mu  <- dbIO (findById {a = User} db uid)
  case mu of
    Just u  => pure (sendJSON u ctx)
    Nothing => throw (MkAppError 404 "user not found")

listUsers : DB -> Handler
listUsers db ctx = do
  rows  <- query db "SELECT id, name, email FROM users ORDER BY id" []
  users <- decodeRows {a = User} rows
  pure (sendJSON users ctx)
```

- **`dbIO : IO (Either PGError a) -> AppProg a`** - lifts any idris2-pg
  call into a Flux handler on the runtime's bounded blocking workers,
  throwing on `Left`. Queue rejection becomes a generic 503. Fully polymorphic, so it
  covers every `IO (Either PGError a)`-shaped call in `flux-db`,
  including `Flux.DB.Crud`'s CRUD helpers and `Flux.DB.Query`'s
  `selectQuery`, with zero extra glue needed.
- **`dbFail : PGError -> AppProg a`** - what `dbIO` throws on failure: a
  plain `500` with a generic, stable public message (`"internal server
  error"`) - the real error (which can name real tables/columns/
  constraints, or echo back a value from the failed query) is logged to
  stderr instead of handed to the client. Exported directly for a
  handler that needs to run something outside `dbIO` (e.g. a manual
  `Either` match) but still wants the same failure behavior.
- **`query`/`command`** - thin `dbIO`-based wrappers over idris2-pg's
  `queryRows`/`execCommand`, for raw SQL that doesn't fit `flux-db`'s
  active-record layer's generic helpers (a join, custom aggregation, a
  non-replace mutation, DDL).
- **`decodeRows`/`decodeOne : FromRow a => List Row -> AppProg (List a)`
  / `AppProg (Maybe a)`** - decode a `query`/raw-SQL result the same way
  `flux-db`'s own generic helpers do, throwing a `500` if a row fails to
  decode (a schema/type mismatch, not a client mistake) rather than a
  `400`. `decodeOne` treats `[]` as `Nothing`, not an error - for a
  query expected to return at most one row (an `UPDATE ... RETURNING`,
  say).
- **`requireIntParam : (name : String) -> Context -> AppProg Integer`**
  / **`requireId : Context -> AppProg Integer`** (= `requireIntParam
  "id"`) - reads and parses a positive-integer path param, failing with
  `400` if it's missing, not a plain non-negative integer, or exceeds
  what a Postgres `BIGINT`/`BIGSERIAL` column can hold. `requireId`
  matches `flux-db`'s `Table`'s own default primary-key-column-name
  convention and Flux's own `:id` path-segment routing convention.

## Pooled repositories

`Flux.DB.Pool` provides `pooledRepository : Pool -> Repository pk a ins`.
Every operation borrows an exclusive connection through `withConnectionIO`;
call repository operations through `dbIO` in handlers. A single `DB` must
never be shared by concurrent handlers.

For several operations in one transaction, use
`withPooledTransactionRepos pool makeRepos callback`. The factory receives
one leased DB and constructs ordinary `pgRepository` values (or an app's
repository extensions). The entire callback uses that connection, and its
`Left` result rolls back before the lease returns. Do not call the global
pooled repository inside that callback: that would borrow a different DB.
Do not retain or fork work using a callback's borrowed DB.

The default pool has eight connections, 128 waiters, and a five-second
acquisition timeout. `closePool` stops admission; active callbacks finish
before their connections close. `poolClosed` observes completed reclamation.
Transport timeouts discard connections. See [idris2-pg](../idris2-pg/README.md)
for timeout limits and the separate `idris2-pg-async` package.

## Error policy and scope

- **Database errors become a flat `500` from `dbIO`/`dbFail`.** Every
  `PGError` - a connection failure, a protocol error, or a genuine SQL
  error - becomes the same 500. An app that wants to turn e.g. a
  unique-constraint violation into a `400` can inspect idris2-pg's
  `SqlError`'s raw Postgres error fields (`Data.PGTypes` - `code`,
  `constraintName`, etc.) itself and throw a more specific `AppError`
  instead of going through `dbFail`/`dbIO`.
- A full or closed blocking worker queue becomes a 503 before any database
  callback starts. Pool acquisition errors currently follow the PGError 500 policy.
- **Postgres-only, via `flux-db`/idris2-pg.** If `flux-db` grows a second
  backend (see its own README's "Backends" section), this package would
  need to grow alongside it, or split further - not designed for yet.

## Install / build

Requires [pack](https://github.com/stefan-hoeck/idris2-pack).

```sh
# From the Flux repository root:
pack --no-prompt build packages/db-flux/flux-db-flux.ipkg
```

## Tests

No dedicated test suite here - `flux-db`'s own tests never exercised this
module either, before or after the split. `todo-api`'s test suite
exercises every function here (`dbIO`/`query`/`command`/`decodeRows`/
`decodeOne`/`requireId`) through its handlers instead; see
`../../apps/todo-api/test/`. Its pooled suite runs the same
behavioral contract and verifies transaction commit/rollback through
`Flux.DB.Pool`; its live HTTP test exercises 24 concurrent clients.
