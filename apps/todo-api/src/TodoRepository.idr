||| The generic CRUD/query operations (`Flux.DB.Repository.Repository`,
||| from flux-db) plus this app's one domain-specific extension
||| `Flux.DB.Crud` has no primitive for: a partial update
||| (`SET done = NOT done`, not a whole-record replace). Flux DB supplies
||| the generic piece and the `decodeFirst` extension point; the
||| domain-specific operation itself is this app's own, not flux-db's -
||| matching the split: flux-db gives every app the same integration
||| pattern, apps define what operations their own domain actually
||| needs.
|||
||| Deliberately no `Flux`/`Flux.DB.PG` import here - nothing in this
||| module needs `Context`/`AppProg`/`Handler`, and importing them would
||| undermine the whole point (a repository handlers can be tested
||| against with zero HTTP framework involved at all - see
||| `test/src/InMemoryRepository.idr`).
module TodoRepository

import Idris2_pg
import Data.PGTypes
import Data.PGValue
import Flux.DB.Field
import Flux.DB.Row
import Flux.DB.Table
import Flux.DB.Repository
import Flux.DB.Crud as Crud
import Models
import Flux.DB.Pool

%default covering

public export
record TodoRepository where
  constructor MkTodoRepository
  crud   : Repository Integer Todo NewTodo
  toggle : Integer -> IO (Either PGError (Maybe Todo))

||| The real, Postgres-backed implementation - `crud` delegates straight
||| to flux-db's `pgRepository`; `toggle` is hand-written SQL (the same
||| shape `Handlers.ActiveRecord.toggleTodo` used to run directly),
||| decoded via flux-db's exported `Flux.DB.Crud.decodeFirst` - the same
||| "single optional row" decode `findById`/`update` use internally,
||| reused here instead of duplicated.
export
pgTodoRepository : DB -> TodoRepository
pgTodoRepository db = MkTodoRepository
  { crud   = pgRepository db
  , toggle = \tid => do
      Right rows <- queryRows db
        "UPDATE todos SET done = NOT done WHERE id = $1 RETURNING id, title, done"
        [Just (show tid)]
        | Left err => pure (Left err)
      pure (Crud.decodeFirst rows)
  }

||| Multi-owner implementation: every operation holds an exclusive pool lease.
export
pooledTodoRepository : Pool -> TodoRepository
pooledTodoRepository pool = MkTodoRepository
  { crud = pooledRepository pool
  , toggle = \tid => withConnectionIO pool (\db => (pgTodoRepository db).toggle tid)
  }
