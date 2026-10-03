||| A small Todo CRUD API demonstrating Flux (HTTP framework) wired up to
||| a real Postgres database via flux-postgres.
|||
||| Main uses an exclusive connection pool. Flux.DB.PG.dbIO runs repository
||| operations on bounded workers, leaving Flux's event loops responsive.
|||
||| Kept separate from `Main` (which just loads config and starts the
||| server) so `test/` can import everything here directly - a real
||| `DB` connection, not a mock - and exercise handlers and routing
||| without needing a live HTTP connection.
|||
||| Wires the LIVE handlers - `Handlers.ActiveRecord` (see that module's
||| own doc comment for why it's the one wired here). `Handlers.
||| TypedQuery` has unwired `listTodos`/`getTodo` alternates built on
||| flux-db's typed query builder instead - a side-by-side comparison,
||| not part of this app's live API surface; see `test/src/Main.idr`'s
||| `queryApp` for where those are actually exercised.
module TodoApi

import public Flux.Core.HTTP
import public Flux.Core.Router
import public Flux.Core.Middleware
import Flux.Middleware.JSON
import public Idris2_pg
import public Data.PGTypes
import public DB.Table
import public Models
import public TodoRepository
import public Handlers.ActiveRecord

%default covering

export
root : Handler
root ctx = pure (sendText "Todo API - see README for routes\n" ctx)

-- A browser preflights any `PUT`/`DELETE` request (both used by the
-- `/todos/:id` routes below) with an `OPTIONS` request first, and only
-- sends the real request if that preflight gets back a 2xx response -
-- `corsAllowAll`'s headers alone aren't enough, since they're set by
-- "before" middleware that still runs ahead of the router's own 404/405
-- for a path with no matching route (see `Flux.Core.Middleware.runApp`),
-- and a browser rejects a preflight whose STATUS isn't 2xx regardless of
-- which headers came back. No route means no 2xx, so every path a
-- browser client can PUT/DELETE to needs its own explicit `OPTIONS`
-- route - this handler is content-free on purpose, since a preflight
-- response's body is never read.
export
preflight : Handler
preflight ctx = pure (setStatus 204 (send (fromString "") ctx))

--------------------------------------------------------------------------------
-- Wiring
--------------------------------------------------------------------------------

export
appRouter : TodoRepository -> Router Handler
appRouter repo =
     empty
  |> get     "/" root
  |> get     "/todos" (listTodos repo)
  |> post    "/todos" (createTodo repo)
  |> options_ "/todos" preflight
  |> get     "/todos/:id" (getTodo repo)
  |> put     "/todos/:id" (updateTodo repo)
  |> delete  "/todos/:id" (deleteTodo repo)
  |> options_ "/todos/:id" preflight
  |> post    "/todos/:id/toggle" (toggleTodo repo)
  |> options_ "/todos/:id/toggle" preflight

export
buildApp : TodoRepository -> App
buildApp repo =
     app
  |> withErrorRenderer jsonErrorRenderer
  |> use corsAllowAll
  |> use secureHeaders
  |> withRoutes (appRouter repo)
