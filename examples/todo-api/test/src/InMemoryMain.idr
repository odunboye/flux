||| The actual proof the repository pattern buys something: the SAME
||| `Handlers.ActiveRecord` handlers, wired through the SAME `TodoApi.
||| buildApp`, run against `InMemoryRepository`'s `TodoRepository` -
||| zero real Postgres connection anywhere in this module (no `Config`/
||| `DevPostgres` import, no `ensureLocalPostgres`, no `PG_TEST_*` env
||| vars needed) and hence a SEPARATE executable from `Main`/`test.ipkg`
||| - the real-Postgres suite provisions a database, connects, and
||| resets the schema before it can run a single check, so folding this
||| into the same entry point would mean the in-memory checks could
||| never actually run without Postgres either, defeating the whole
||| point of having a zero-Postgres test double in the first place.
|||
||| Runs the exact same `RepositoryBehavior.repositoryBehaviorChecks`
||| `Main`'s own scenario does against the real Postgres-backed
||| repository - not a separately-written, narrower smoke pass - so a
||| behavioral divergence between the two `TodoRepository`
||| implementations is a real test failure here, not something that
||| could silently go unnoticed.
module InMemoryMain

import TestHarness
import RepositoryBehavior
import TodoApi
import InMemoryRepository
import Data.IORef

%default covering

covering
main : IO ()
main = do
  putStrLn "Running in-memory TodoRepository scenario (no Postgres involved) ...\n"
  inMemoryRepo <- inMemoryTodoRepository
  let application = buildApp inMemoryRepo

  st <- Data.IORef.newIORef (MkTestState 0 [])
  repositoryBehaviorChecks st application
  report st
