# todo-api

A small Todo CRUD API demonstrating [Flux](../..) (an
Idris2 HTTP framework) wired up to a real Postgres database via
[idris2-pg](../../packages/postgres) (a from-scratch, primitive Postgres
wire-protocol client, no `libpq`), through [flux-db](../../packages/db)
(the derivable active-record layer built on top of idris2-pg - `Row`<->
record mapping, generated CRUD, a typed query builder, and a generic
repository pattern - see "Repository pattern" below) and
[flux-db-flux](../../packages/db-flux) (the glue lifting idris2-pg's own
error type into Flux's `AppProg` - split into its own package so
`flux-db` itself has no Flux dependency).

## Run it

Requires [pack](https://github.com/stefan-hoeck/idris2-pack). Docker is
optional but recommended - if it's installed and reachable, the app
manages its own local Postgres container automatically (see "Automatic
local Postgres" below); without it, point `PGHOST`/etc at a Postgres
you're already running.

```sh
pack build todo-api.ipkg
./build/exec/todo-api 8080 1
```

The schema (one `todos` table) is created automatically on startup
(`CREATE TABLE IF NOT EXISTS`) - no separate migration step.

Connection details come from the standard libpq env vars -
`PGHOST`/`PGPORT`/`PGUSER`/`PGPASSWORD`/`PGDATABASE` - defaulting to
`127.0.0.1:5432` / `testuser` / `testpass` / `testdb`.

### Automatic local Postgres

`src/DevPostgres.idr`'s `ensureLocalPostgres` (used by both the app and
its test suite, in place of a plain `connectDB`) wraps
[idris2-docker](../../packages/docker), a general-purpose
container-management library, with Postgres-specific glue: on startup, if
`PGHOST` is local (`127.0.0.1`/`localhost`) and `docker` is installed and
reachable, it creates the `todo-api-pg` container if it doesn't exist yet,
starts it if it exists but is stopped, and does nothing if it's already
running - then waits (bounded retries, a real `connectDB` each time) until
Postgres actually accepts a connection. Every one of these steps is purely
advisory: if Docker isn't available, or `PGHOST` points somewhere remote,
or you opt out (below), it falls straight through to exactly what a plain
`connectDB cfg` does today - this is never a *new* way for the app to
fail that a manual `docker run` + `connectDB` didn't already have.

The container it creates matches the connection env vars above
(`POSTGRES_USER`/`POSTGRES_PASSWORD`/`POSTGRES_DB` from
`PGUSER`/`PGPASSWORD`/`PGDATABASE`, port mapping from `PGPORT`) - so it's
equivalent to running this by hand once:

```sh
docker run -d --name todo-api-pg \
  -e POSTGRES_USER=testuser -e POSTGRES_PASSWORD=testpass -e POSTGRES_DB=testdb \
  -p 5432:5432 postgres:16
```

which still works fine as a manual/fallback override if you'd rather
manage the container yourself - `ensureLocalPostgres` sees it's already
running and just connects.

Two opt-outs:

- `TODO_API_SKIP_DOCKER=1` - never touch Docker, go straight to
  `connectDB cfg`.
- Point `PGHOST` at anything non-local - Docker management only ever
  kicks in for a loopback host in the first place.

If the container is already running but was started against a different
`PGPORT` than the app is currently configured with, startup logs a
warning (rather than silently connecting to the wrong thing or hanging) -
e.g. a stale container left over from an earlier config.

Teardown stays manual - the app never stops or removes the container on
exit, since that'd be surprising for something you might want to keep
data in between runs: `docker stop todo-api-pg` / `docker rm todo-api-pg`
when you're done with it. Override the container name with
`TODO_API_PG_CONTAINER` if you want more than one instance side by side.

## Routes

| Method | Path              | Body                          | Notes                    |
|--------|-------------------|--------------------------------|---------------------------|
| GET    | `/todos`          | -                               | list all, ordered by id  |
| POST   | `/todos`          | `{"title": "..."}`             | 201, returns the new todo |
| GET    | `/todos/:id`      | -                               | 404 if missing            |
| PUT    | `/todos/:id`      | `{"title": "...", "done": ...}` | full replace, 404 if missing |
| POST   | `/todos/:id/toggle` | -                             | flips `done`, 404 if missing |
| DELETE | `/todos/:id`      | -                               | 204, 404 if missing       |

```sh
curl -X POST localhost:8080/todos -d '{"title":"Buy milk"}'
curl localhost:8080/todos
curl -X POST localhost:8080/todos/1/toggle
curl -X PUT localhost:8080/todos/1 -d '{"title":"Buy milk and eggs","done":true}'
curl -X DELETE localhost:8080/todos/1
```

## Row<->record mapping and CRUD

`TodoApi.idr`'s `Todo` record uses [flux-db](../../packages/db)'s
derivable "active-record" layer rather than hand-written `Row`
decoding/SQL:

```idris
TodoTable : List Name -> ParamTypeInfo -> Res (List TopLevel)
TodoTable = customTable Export (Just "todos") Nothing [("done", "false")]

%runElab derive "Todo" [ToJSON, FromJSON, Eq, Show, FromRow, ToRow, TodoTable]
```

`FromRow`/`ToRow` generate `Row<->Todo` mapping per field (replacing what
used to be a hand-written `rowToTodo`); `TodoTable` generates the table
metadata and fixed SQL text `getTodo`/`createTodo`/`updateTodo`/
`deleteTodo` now run through `Flux.DB.Crud`'s generic `findById`/`insert`/
`update`/`deleteById`, instead of each handler building its own SQL
string. The `Just "todos"` override is required, not optional - the real
Postgres table is `todos` (plural) while the Idris type is `Todo`
(singular), and `Table`'s default naming (exact-lowercase of the type
name) doesn't guess plurals.

`TodoTable` also generates `createTableSql` - `Main.idr`/
`test/src/Main.idr` both call `execCommand db (createTableSql {a = Todo})
[]` instead of running a hand-written `CREATE TABLE IF NOT EXISTS`
string. `[("done", "false")]` is flux-db's take on
[Drift](https://github.com/simolus3/drift)'s `withDefault()` - a real
`DEFAULT false` on `done` at the DB level (confirmed with `\d todos`:
`done | boolean | not null | false`). It isn't load-bearing for
`createTodo` itself, which always supplies `done` explicitly via
`NewTodo` below - this codebase's own equivalent of Drift's *other*
default kind, `clientDefault()` (an application-side default, no schema
support needed) - kept on the column anyway to preserve the exact
schema this table already had, and to prove the override is real.

`insert` needs a value for `id` even though Postgres generates the real
one (now `BIGSERIAL`, chosen by `createTableSql` to match `Integer`'s
own pairing elsewhere in flux-db - previously a hand-written `SERIAL`),
so it takes a second, pk-less record instead of `Todo` itself.
`flux-db`'s `deriveInsertable` generates that record - and its
`ToRow` instance, and the link back to `Todo` - in one line, so
`TodoApi.idr` never hand-writes it:

```idris
%runElab deriveInsertable Nothing "Todo"
```

This declares `NewTodo`/`MkNewTodo` (every `Todo` field except `id`), a
`ToRow NewTodo` instance, and `Insertable NewTodo Todo` - exactly what
hand-writing the record plus those two derives/instances would have
produced, just without the boilerplate. `createTodo` constructs it the
same way either way: `insert {a = Todo} db (MkNewTodo title False)`.

Handlers don't call `insert`/`findById`/`update`/`deleteById` directly
against a raw `DB` any more, though - see "Repository pattern" below for
what they actually go through, and why.

`TodoUpdate` (the PUT body's shape) is generated the same way, via
`flux-db`'s more general `deriveSubset` - the include-list version of
what `deriveInsertable` does:

```idris
%runElab deriveSubset ["title", "done"] "TodoUpdate" [FromJSON] "Todo"
```

This declares `TodoUpdate`/`MkTodoUpdate` (only `title` and `done`, with
real field accessors - `tu.title` works exactly as if it had been
hand-written) and a `FromJSON TodoUpdate` instance. Deliberately an
include-list, not `id` minus an exclude-list like `NewTodo` above: the
PUT body's accepted fields are an HTTP-API decision, not a database one,
and shouldn't silently grow just because `Todo` gains a column later
that happens to not be the primary key.

The create endpoint's `{"title": ...}` body is generated the same way,
via `deriveSubset` again - but with a local `ObjectFromJSON`
(`src/ObjectFromJSON.idr`) in place of `json-simple`'s own `FromJSON`:

```idris
%runElab deriveSubset ["title"] "NewTodoBody" [ObjectFromJSON] "Todo"
```

`json-simple`'s own `FromJSON` derive treats a *single-field* record as
a "newtype" and (de)serializes it as the bare inner value
(`"Buy milk"`) rather than `{"title":"Buy milk"}` - confirmed directly
against this exact dependency version, and confirmed again by reading
its derive's own source: a plain, untagged single-constructor record
always takes this path for its one-and-only field, with no `Options`
flag able to turn it off without also switching to sum-type-shaped
tagging (`{"tag":...,"contents":...}`), which isn't the wire format we
want either. `ObjectFromJSON` (now [flux-db](../../packages/db)'s, not
local to this project - see flux-db's own README) is a from-scratch
`FromJSON` derivation - pure JSON, no DB coupling - that always decodes
as a plain object regardless of field count, built the same way (and
composable the same way, as one more item in `deriveSubset`'s `derives`
list) as everything in "Row<->record mapping and CRUD" above. This
replaces what used to be a hand-rolled `parseNewTodo`, which decoded
into `json-simple`'s own generic `JSON` value and pulled `"title"` out
manually purely to route around the same quirk.

## Repository pattern

`Handlers/ActiveRecord.idr`'s six handlers take a `TodoRepository`
(`src/TodoRepository.idr`), not a raw `DB`:

```idris
public export
record TodoRepository where
  constructor MkTodoRepository
  crud   : Repository Integer Todo NewTodo  -- flux-db's Flux.DB.Repository
  toggle : Integer -> IO (Either PGError (Maybe Todo))
```

`crud` is [flux-db](../../packages/db)'s generic `Flux.DB.Repository`
(`findById`/`insert`/`update`/`deleteById`/`query`) - free once `Todo`
has the `Table`/`FromRow`/`ToRow`/`Insertable NewTodo Todo` instances
already derived above. `toggle` is this app's own domain-specific
extension - a partial update (`SET done = NOT done`) flux-db's generic
CRUD has no primitive for - hand-written SQL decoded via flux-db's
exported `Flux.DB.Crud.decodeFirst`, the same "single optional row"
helper `findById`/`update` use internally, reused instead of duplicated.
A handler looks like:

```idris
getTodo : TodoRepository -> Handler
getTodo repo ctx = do
  tid <- requireId ctx
  mt  <- dbIO (repo.crud.findById tid)
  case mt of
    Just todo => pure (sendJSON todo ctx)
    Nothing   => throw (MkAppError 404 "todo not found")
```

Plain values, no `Context`/status codes/`AppProg` anywhere in
`TodoRepository` itself - the handler decides a missing todo becomes a
404, not the repository. `dbIO` (flux-db-flux) lifts the result into
`AppProg` the same way it already lifts every other `IO (Either PGError
a)`-shaped call.

`pgTodoRepository : DB -> TodoRepository` (constructed once in `Main`)
is the real, Postgres-backed implementation. `test/src/
InMemoryRepository.idr` provides a second one - `IORef`-backed, zero
Postgres connection - and both implementations are exercised through the
exact same `RepositoryBehavior.repositoryBehaviorChecks` (see "Tests"
below): the actual proof the pattern buys something (substitutability),
not just a restructuring. See flux-db's own README for
`Flux.DB.Repository`'s design (why it's a record of functions, not an
interface; why the primary key `pk` is generic, not hardcoded; the
`withTransactionRepos` combinator for atomic multi-repository writes -
`Todo` is a single-table model with no natural use for it yet, so it's
only exercised in flux-db's own test suite, not here).

`Handlers/TypedQuery.idr` is deliberately **not** migrated to
`TodoRepository` - it still takes a raw `DB` directly. It's already
framed as an unwired, side-by-side comparison (see below), and
migrating it wouldn't demonstrate anything the repository pattern itself
needs to prove - a reasonable later cleanup, not done here.

## Two ways to query: active record vs. typed query builder

`src/Handlers/` has two implementations of `listTodos`/`getTodo`, in
separate files, demonstrating flux-db's two query layers side by side on
the same two operations:

- **`Handlers/ActiveRecord.idr`** - the live version, wired into
  `TodoApi.appRouter`. `getTodo` uses `Flux.DB.Crud`'s `findById`;
  `listTodos` falls back to hand-written SQL decoded through the
  derived `FromRow` instance, since `Flux.DB.Crud` has no generic "list
  all" primitive (only by-pk `insert`/`findById`/`update`/`deleteById`).
  This file also has the other four handlers (`createTodo`/`updateTodo`/
  `toggleTodo`/`deleteTodo`) - see below for why they don't get a second
  version.
- **`Handlers/TypedQuery.idr`** - `listTodos`/`getTodo` reimplemented via
  flux-db's typed query builder instead (`Flux.DB.Query`'s `selectQuery`,
  `Models`'s derived `todoColumns`):
  ```idris
  listTodos db ctx = do
    todos <- dbIO (selectQuery {a = Todo} db (selectAll |> orderByAsc todoColumns.id))
    pure (sendJSON todos ctx)
  ```
  Not wired into `appRouter` - kept as an unwired comparison, exercised
  only in `test/src/Main.idr`'s `queryApp` (a second, test-only `App`
  at the same paths), which asserts both versions return byte-identical
  responses against the same live data, including after mutations made
  through the active-record routes.

Only `listTodos`/`getTodo` get two versions. `Flux.DB.Query` is
deliberately `SELECT`-only (no bulk `updateWhere`/`deleteWhere` by
condition - see flux-db's own README) - `createTodo`/`updateTodo`/
`toggleTodo`/`deleteTodo` are mutations with no typed-query-builder
equivalent to write, not an oversight.

## Tests

Two separate executables, built from two separate `.ipkg` files in
`test/` - deliberately not one, so the in-memory suite can never
accidentally require Postgres to run (see below).

### `test.ipkg` - against a real Postgres

Handler-level tests, run against a real Postgres (no mock DB - see "Two
things worth knowing" below for why). Drives every route through
`runApp` directly (real routing, real JSON encode/decode, real DB
round-trips), the same way Flux's own test suite exercises `runApp`
end-to-end - not through a live HTTP connection.

The `todos` table is dropped and recreated before the suite runs, so
ids are deterministic (`SERIAL` always starts at 1 against a fresh
table) regardless of what the app itself, or a previous test run, left
behind. Connection details come from their own, separate env vars -
`PG_TEST_HOST`/`PG_TEST_PORT`/`PG_TEST_USER`/`PG_TEST_PASSWORD`/
`PG_TEST_DB` (`Config.loadTestConfig`), matching idris2-pg's and
flux-db's own test suites' convention - deliberately **not**
`PGHOST`/`PGPORT`/`PGUSER`/`PGPASSWORD`/`PGDATABASE` (what `Main` itself
reads via `Config.loadConfig`). The default *database name* is also
deliberately different (`todo_api_test` here, `testdb` for the app) -
not just a different env-var namespace - so running the test suite with
**no configuration at all** still can't collide with the app's own
default target; `Config.ensureTestDatabase` creates this database
automatically (via a throwaway connection to Postgres's own `postgres`
maintenance database) the first time it doesn't already exist, so
there's no manual setup step either way. Provisioning the shared local
container itself goes through a third, FIXED identity
(`Config.localDevConfig`, never read from any env var) - independent of
both `loadConfig` and `loadTestConfig` - so an app pointed at a remote
database via `PGHOST` can never block or redirect test provisioning,
and a test run never unintentionally contacts a real app's remote
database just to make sure some local Postgres is up. This local
provisioning step is also conditional: it only runs when `PG_TEST_*`
itself targets that exact host+port (`127.0.0.1:5432`) - a
genuinely remote `PG_TEST_HOST`, or even just a different port on
`127.0.0.1` (a second local Postgres instance, say), skips it entirely,
so a valid remote-or-alternate-port test target never depends on that
unrelated well-known local container being reachable at all.

```sh
cd test
pack build test.ipkg
./build/exec/todo-api-test
```

26 checks: the state-independent BIGINT-range check and root route,
`RepositoryBehavior.repositoryBehaviorChecks` (see below - 20 checks),
`Handlers.TypedQuery`'s `listTodos`/`getTodo` cross-checked once against
`Handlers.ActiveRecord`'s versions on whatever live data the behavioral
pass left behind (see "Two ways to query" above), and a check that a
genuine DB-side error (the table dropped out from under a live request)
comes back redacted to flux-db-flux's generic public message, not the
real Postgres error text.

### `inmemory-test.ipkg` - zero Postgres

A second, independent executable - `InMemoryMain`, not `Main` - running
the same six `Handlers.ActiveRecord` handlers, through the same
`TodoApi.buildApp`, against `InMemoryRepository`'s `TodoRepository`
instead of a real one (see "Repository pattern" above). No `Config`/
`DevPostgres` import anywhere in this executable's own dependency
chain, no Docker, no `PG_TEST_*` env vars needed - genuinely can't touch
a database even by accident. Deliberately a separate executable rather
than folded into `test.ipkg`'s own `main`: the real-Postgres suite has
to provision a database, connect, and reset the schema before it can
run a single check, so running the in-memory checks from that same
entry point would mean they could never actually execute without
Postgres either - exactly the coupling this avoids.

```sh
cd test
pack build inmemory-test.ipkg
./build/exec/todo-api-inmemory-test
```

20 checks - the exact same `RepositoryBehavior.repositoryBehaviorChecks`
`test.ipkg`'s own scenario runs against the real Postgres-backed
repository (create/get/update/toggle/delete, validation, the ordering
regression, all of it), not a separately-written, narrower smoke pass.
Both suites literally share this one check function
(`test/src/RepositoryBehavior.idr`), run against `TodoRepository`'s two
implementations - a behavioral divergence between them is a real test
failure in whichever suite hits it first, not something that could
silently go unnoticed. Deliberately excludes anything Postgres-only
(BIGINT range, `Handlers.TypedQuery` comparison, real-SQL error
redaction) - those stay in `test.ipkg`'s own scenario.

Both executables also share request-building/response-parsing/pass-fail
bookkeeping via `test/src/TestHarness.idr` rather than duplicating it.

## Database concurrency

The running app uses `pooledTodoRepository` with `Data.PGPool` defaults:
8 exclusive connections, 128 queued acquirers, and a 5-second acquisition
deadline. Database operations run on bounded workers through `Flux.DB.PG.dbIO`.
Set `FLUX_EVENT_LOOPS` to choose HTTP owner threads; the default is 2.

Tests can still supply `pgTodoRepository db` or the in-memory implementation.
A raw repository bound to one DB must not be used concurrently. For operations
that must be atomic together, borrow one connection for the complete callback
with `withPooledTransactionRepos`, rather than invoking independent pooled
CRUD operations inside a transaction.

The pool supplies finite connect/read deadlines when the app config omits
them. Timed-out connections are closed and replaced. Bootstrap container and
schema setup still run before the HTTP server starts.
