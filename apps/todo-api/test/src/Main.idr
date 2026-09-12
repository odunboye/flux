||| Handler-level tests for todo-api, run against a real Postgres (no
||| mock DB - idris2-pg's `DB` is a concrete connection, not an
||| interface, and this project's own README already explains why that's
||| an acceptable tradeoff for a demo). Uses the same `ensureLocalPostgres`
||| (see `DevPostgres`) the app itself does, so no manual Docker step is
||| needed here either; connection details come from `Config.
||| loadTestConfig`'s OWN `PG_TEST_HOST`/`PG_TEST_PORT`/`PG_TEST_USER`/
||| `PG_TEST_PASSWORD`/`PG_TEST_DB` env vars - deliberately NOT
||| `loadConfig`'s `PGHOST`/etc (what `Main` itself reads) - so pointing
||| the real app at a remote/production database can never also
||| redirect this suite's `DROP TABLE IF EXISTS todos` there.
|||
||| Drives each handler directly through `runApp` (real routing, real
||| JSON encode/decode, real DB round-trips) rather than hand-building a
||| `Context` per handler - matches how Flux's own test suite exercises
||| `runApp` end-to-end. The table is dropped and recreated before the
||| suite runs so ids are deterministic (Postgres `SERIAL` always starts
||| at 1 against a fresh table) - tests are written as one ordered
||| scenario, not independent cases, since each one's expected state
||| depends on the ones before it (the same shape as idris2-pg's own CRUD
||| smoke test).
|||
||| The zero-Postgres in-memory-repository suite is a SEPARATE executable
||| (`InMemoryMain`/`inmemory-test.ipkg`) - not run from here - precisely
||| so it never needs a real database to run at all; see that module's
||| own doc comment for why.
module Main

import TestHarness
import RepositoryBehavior
import TodoApi
import Handlers.TypedQuery as TypedQuery
import Flux.Middleware.JSON
import DevPostgres
import Config
import Models
import JSON.Simple
import Data.IORef
import Data.String
import System

%default covering

-- A second, test-only `App` wiring `Handlers.TypedQuery`'s `listTodos`/
-- `getTodo` (nebula's typed-query-builder versions) at the same paths
-- the real app uses - a separate `Router`/`App` value, never merged
-- into `TodoApi.appRouter`, so this exists purely to compare its output
-- against `Handlers.ActiveRecord`'s versions (wired in `TodoApi.
-- appRouter`) against the exact same live data, not to add a second
-- live route.
queryApp : DB -> App
queryApp db =
     app
  |> withErrorRenderer jsonErrorRenderer
  |> withRoutes
       (    empty
        |> get "/todos" (TypedQuery.listTodos db)
        |> get "/todos/:id" (TypedQuery.getTodo db)
       )

--------------------------------------------------------------------------------
-- The scenario
--------------------------------------------------------------------------------

covering
scenario : Data.IORef.IORef TestState -> DB -> App -> App -> IO ()
scenario st db application queryApplication = do
  let go = check st

  -- root route still works alongside the DB-backed ones - state-
  -- independent, doesn't matter that it runs before the behavioral pass.
  r2 <- run application (mkRequest GET "/")
  go "root: 200 plain text" (r2.status == 200 && Data.String.isInfixOf "Todo API" r2.body)

  -- get an id that's all-digit (so it passes requireId's digit check)
  -- but exceeds what a Postgres BIGINT/BIGSERIAL column can hold -
  -- regression test for Nebula.PG.requireIntParam's range check: this
  -- must be rejected at the request boundary with a 400, not reach the
  -- database and surface as an opaque 500. Also state-independent.
  r9b <- run application (mkRequest GET "/todos/99999999999999999999999999")
  go "getTodo: id above BIGINT range is 400, not 500"
    (r9b.status == 400 && Data.String.isInfixOf "out of range" r9b.body)

  -- The shared behavioral contract (create/get/update/toggle/delete,
  -- ordering) - the SAME check function `InMemoryMain` runs against the
  -- in-memory double, so a divergence between the two `TodoRepository`
  -- implementations is a real failure, not silently unnoticed. Starts
  -- on an empty table, ends with only todo 2 ("Write more Idris", done)
  -- left.
  repositoryBehaviorChecks st application

  -- Handlers.TypedQuery's listTodos/getTodo (nebula's typed-query-
  -- builder versions) must agree with Handlers.ActiveRecord's, against
  -- whatever live data the behavioral pass above left behind - both
  -- nebula query layers reading the same table, checked once against a
  -- realistic post-mutation state rather than at several mid-pipeline
  -- points (the underlying claim - "both layers agree" - doesn't need
  -- more than one checkpoint to prove).
  rqList <- run queryApplication (mkRequest GET "/todos")
  acList <- run application (mkRequest GET "/todos")
  go "TypedQuery.listTodos matches Handlers.ActiveRecord.listTodos"
    (rqList.status == acList.status && rqList.body == acList.body)

  rqGet <- run queryApplication (mkRequest GET "/todos/2")
  acGet <- run application (mkRequest GET "/todos/2")
  go "TypedQuery.getTodo matches Handlers.ActiveRecord.getTodo (existing id)"
    (rqGet.status == acGet.status && rqGet.body == acGet.body)

  rqMissing <- run queryApplication (mkRequest GET "/todos/999")
  go "TypedQuery.getTodo: missing id is 404" (rqMissing.status == 404)

  -- Error redaction: a genuine DB-side error (not a client mistake)
  -- must return the generic public message, not the real Postgres
  -- error text (which can name real tables/columns/constraints) -
  -- regression test for Nebula.PG.dbFail's log-and-redact policy.
  -- Dropping the table out from under a live request forces a real
  -- SqlError ("relation \"todos\" does not exist") - the response body
  -- must not contain any of that, only the generic message. Last check
  -- in this scenario (destroys the table), so leaving it dropped
  -- afterward is fine.
  _   <- execCommand db "DROP TABLE todos" []
  r19 <- run application (mkRequest GET "/todos")
  go "listTodos: a real DB error is redacted to a generic message"
    (r19.status == 500 && r19.body == #"{"error":"internal server error"}"#)

--------------------------------------------------------------------------------
-- Entry point
--------------------------------------------------------------------------------

covering
main : IO ()
main = do
  cfg <- loadTestConfig
  Right () <- ensureTestDatabase cfg
    | Left err => do
        putStrLn "Failed to ensure test database \{cfg.database} exists: \{displayError err}"
        exitFailure
  putStrLn "Connecting to Postgres at \{cfg.host}:\{show cfg.port}/\{cfg.database} ..."
  Right db <- ensureLocalPostgres cfg
    | Left err => do
        putStrLn "Failed to connect to Postgres: \{displayError err}"
        exitFailure
  -- Reset to a known, empty state so ids are deterministic (SERIAL
  -- starts at 1 against a fresh table) regardless of what a previous
  -- test run, or the app itself, left behind.
  Right _ <- execCommand db "DROP TABLE IF EXISTS todos" []
    | Left err => do putStrLn "Failed to reset schema: \{displayError err}"; exitFailure
  Right _ <- execCommand db (createTableSql {a = Todo}) []
    | Left err => do putStrLn "Failed to create schema: \{displayError err}"; exitFailure
  putStrLn "Connected. Schema reset.\n"

  let repo             = pgTodoRepository db
      application      = buildApp repo
      queryApplication = queryApp db

  st <- Data.IORef.newIORef (MkTestState 0 [])
  scenario st db application queryApplication
  closeDB db
  report st
