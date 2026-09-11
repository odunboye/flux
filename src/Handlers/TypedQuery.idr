||| `listTodos`/`getTodo` reimplemented via nebula's typed query builder
||| (`Data.PGQuery`'s `Column`/`Condition`/`Query`/`selectQuery`,
||| `Models`'s derived `todoColumns`) instead of `Handlers.ActiveRecord`'s
||| hand-written-SQL/`findById` versions - a side-by-side comparison of
||| nebula's two query layers on the same two operations, kept separate
||| from the live API surface (see `TodoApi.appRouter`, which wires
||| `Handlers.ActiveRecord`'s versions, not these) and exercised only in
||| `test/src/Main.idr`'s `queryApp`.
|||
||| Only these two exist here, not all six `Handlers.ActiveRecord`
||| handlers - `Data.PGQuery` is deliberately `SELECT`-only (see its own
||| doc comment/nebula's README: no bulk `updateWhere`/`deleteWhere` by
||| condition, not built yet), so `createTodo`/`updateTodo`/`toggleTodo`/
||| `deleteTodo` (all mutations) have no typed-query-builder equivalent
||| to write - `Handlers.ActiveRecord`'s versions are the only ones that
||| exist for those, full stop, not "the active-record pick between two
||| options" the way `listTodos`/`getTodo` are here.
module Handlers.TypedQuery

import public Flux.Core.HTTP
import Flux.Middleware.JSON
import public Idris2_pg
import public Data.PGTypes
import Data.PGField
import Data.PGRow
import public Data.PGTable
import Data.PGQuery
import Nebula.PG
import Models

%default covering

export
listTodos : DB -> Handler
listTodos db ctx = do
  todos <- dbIO (selectQuery {a = Todo} db (selectAll |> orderByAsc todoColumns.id))
  pure (sendJSON todos ctx)

export
getTodo : DB -> Handler
getTodo db ctx = do
  tid   <- requireId ctx
  todos <- dbIO (selectQuery {a = Todo} db (where_ (todoColumns.id ==. tid) selectAll))
  case todos of
    (todo :: _) => pure (sendJSON todo ctx)
    []          => throw (MkAppError 404 "todo not found")
