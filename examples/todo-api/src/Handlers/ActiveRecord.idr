||| Todo handlers built on `TodoRepository` (flux-db's generic
||| `DB.Repository.Repository`, plus this app's own `toggle`
||| extension) instead of a raw `DB` - the version wired into
||| `TodoApi.appRouter`. Every handler here is HTTP-glue only: read a
||| path param/body, call the repository, decide what a `Nothing`/
||| `False` result becomes (a 404, mostly). See `test/src/
||| InMemoryRepository.idr` for the actual proof this buys something -
||| these exact handlers run against a zero-Postgres in-memory
||| `TodoRepository` there too.
|||
||| See `Handlers.TypedQuery` for `listTodos`/`getTodo` reimplemented via
||| flux-db's typed query builder instead (`DB.Query`'s
||| `selectQuery`/`where_`/`orderByAsc`, called directly against a raw
||| `DB` - deliberately NOT migrated to `TodoRepository` in this pass,
||| since it's already a side-by-side comparison kept separate from the
||| live API surface, not part of what the repository pattern itself
||| needs to demonstrate) - kept unwired, only exercised in
||| `test/src/Main.idr`'s `queryApp`.
module Handlers.ActiveRecord

import public Flux.Core.HTTP
import Flux.Middleware.JSON
import JSON.Simple
import public Idris2_pg
import public Data.PGTypes
import Flux.DB.PG
import DB.Query
import DB.Repository
import TodoRepository
import Models

%default covering

export
listTodos : TodoRepository -> Handler
listTodos repo ctx = do
  todos <- dbIO (repo.crud.query (selectAll |> orderByAsc todoColumns.id))
  pure (sendJSON todos ctx)

export
createTodo : TodoRepository -> Handler
createTodo repo ctx = do
  nb   <- requireJsonBody {a = NewTodoBody} 65536 "invalid JSON body - expected {\"title\":...}" ctx
  todo <- dbIO (repo.crud.insert (MkNewTodo nb.title False))
  pure (setStatus 201 (sendJSON todo ctx))

export
getTodo : TodoRepository -> Handler
getTodo repo ctx = do
  tid <- requireId ctx
  mt  <- dbIO (repo.crud.findById tid)
  case mt of
    Just todo => pure (sendJSON todo ctx)
    Nothing   => throw (MkAppError 404 "todo not found")

export
updateTodo : TodoRepository -> Handler
updateTodo repo ctx = do
  tid <- requireId ctx
  tu  <- requireJsonBody {a = TodoUpdate} 65536 "invalid JSON body - expected {\"title\":...,\"done\":...}" ctx
  mt  <- dbIO (repo.crud.update (MkTodo tid tu.title tu.done))
  case mt of
    Just todo => pure (sendJSON todo ctx)
    Nothing   => throw (MkAppError 404 "todo not found")

export
toggleTodo : TodoRepository -> Handler
toggleTodo repo ctx = do
  tid <- requireId ctx
  mt  <- dbIO (repo.toggle tid)
  case mt of
    Just todo => pure (sendJSON todo ctx)
    Nothing   => throw (MkAppError 404 "todo not found")

export
deleteTodo : TodoRepository -> Handler
deleteTodo repo ctx = do
  tid <- requireId ctx
  deleted <- dbIO (repo.crud.deleteById tid)
  case deleted of
    True  => pure (setStatus 204 ctx)
    False => throw (MkAppError 404 "todo not found")
