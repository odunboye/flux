||| A pure in-memory `TodoRepository`, backed by an `IORef (List Todo)`
||| + a next-id counter - demonstrates the repository pattern's actual
||| payoff (a handler written against `TodoRepository` doesn't care
||| which implementation it's given) with zero real Postgres connection.
|||
||| `query` only meaningfully supports the two shapes
||| `Handlers.ActiveRecord.listTodos` actually calls - bare `selectAll`
||| and `selectAll |> orderByAsc todoColumns.id` (sorted by `id`
||| ascending, matching what a real `ORDER BY id` on the Postgres side
||| does). Any other `Query` shape (a `WHERE` condition, `LIMIT`/
||| `OFFSET`, ordering by a different column) fails loudly (`Left
||| (ProtocolError ...)`) rather than silently returning the wrong data
||| - a real `Flux.DB.Query.Condition`/general-order evaluator against
||| plain Idris values is real, currently-unneeded work; failing loud
||| instead of guessing wrong is the safe default until something
||| actually needs it.
module InMemoryRepository

import Data.IORef
import Data.List
import Idris2_pg
import Data.PGTypes
import Flux.DB.Repository
import Flux.DB.Query
import TodoRepository
import Models

%default covering

export
inMemoryTodoRepository : IO TodoRepository
inMemoryTodoRepository = do
  store  <- newIORef {a = List Todo} []
  nextId <- newIORef {a = Integer} 1
  pure $ MkTodoRepository
    { crud = MkRepository
        { findById   = \tid => Right . find (\t => t.id == tid) <$> readIORef store
        , insert     = \nb => do
            tid <- readIORef nextId
            modifyIORef nextId (+1)
            let todo := MkTodo tid nb.title nb.done
            modifyIORef store (++ [todo])
            pure (Right todo)
        , update     = \upd => do
            todos <- readIORef store
            case find (\t => t.id == upd.id) todos of
              Nothing => pure (Right Nothing)
              Just _  => do
                writeIORef store (map (\t => if t.id == upd.id then upd else t) todos)
                pure (Right (Just upd))
        , deleteById = \tid => do
            todos <- readIORef store
            let (kept, removed) := partition (\t => t.id /= tid) todos
            writeIORef store kept
            pure (Right (not (isNil removed)))
        , query      = \q => case q of
            MkQuery Nothing []            Nothing Nothing => Right <$> readIORef store
            MkQuery Nothing [("id", Asc)] Nothing Nothing =>
              Right . sortBy (\a, b => compare a.id b.id) <$> readIORef store
            _ => pure (Left (ProtocolError "in-memory repository does not support this Query shape"))
        }
    , toggle = \tid => do
        todos <- readIORef store
        case find (\t => t.id == tid) todos of
          Nothing   => pure (Right Nothing)
          Just todo => do
            let toggled := { done $= not } todo
            writeIORef store (map (\t => if t.id == tid then toggled else t) todos)
            pure (Right (Just toggled))
    }
