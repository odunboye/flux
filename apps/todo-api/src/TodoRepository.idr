||| The generic CRUD/query operations (`Data.PGRepository.Repository`,
||| from nebula) plus this app's one domain-specific extension
||| `Data.PGCrud` has no primitive for: a partial update
||| (`SET done = NOT done`, not a whole-record replace). Nebula supplies
||| the generic piece and the `decodeFirst` extension point; the
||| domain-specific operation itself is this app's own, not nebula's -
||| matching the split: nebula gives every app the same integration
||| pattern, apps define what operations their own domain actually
||| needs.
|||
||| Deliberately no `Flux`/`Nebula.PG` import here - nothing in this
||| module needs `Context`/`AppProg`/`Handler`, and importing them would
||| undermine the whole point (a repository handlers can be tested
||| against with zero HTTP framework involved at all - see
||| `test/src/InMemoryRepository.idr`).
module TodoRepository

import Idris2_pg
import Data.PGTypes
import Data.PGValue
import Data.PGField
import Data.PGRow
import Data.PGTable
import Data.PGRepository
import Data.PGCrud as Crud
import Models
import Nebula.Pool

%default covering

public export
record TodoRepository where
  constructor MkTodoRepository
  crud   : Repository Integer Todo NewTodo
  toggle : Integer -> IO (Either PGError (Maybe Todo))

||| The real, Postgres-backed implementation - `crud` delegates straight
||| to nebula's `pgRepository`; `toggle` is hand-written SQL (the same
||| shape `Handlers.ActiveRecord.toggleTodo` used to run directly),
||| decoded via nebula's exported `Data.PGCrud.decodeFirst` - the same
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
