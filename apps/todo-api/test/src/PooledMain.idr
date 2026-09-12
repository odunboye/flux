module PooledMain

import TestHarness
import RepositoryBehavior
import TodoApi
import TodoRepository
import Models
import Config
import Nebula.Pool
import Data.PGRepository
import Data.PGValue
import Data.IORef
import System

%default covering

main : IO ()
main = do
  cfg <- loadTestConfig
  Right () <- ensureTestDatabase cfg
    | Left err => putStrLn (displayError err) >> exitFailure
  Right pool <- newPool (MkPoolConfig 2 128 5000) cfg
    | Left err => putStrLn (displayError err) >> exitFailure
  Right () <- withConnectionIO pool (\db => do
    Right _ <- execCommand db "DROP TABLE IF EXISTS todos" []
      | Left err => pure (Left err)
    Right _ <- execCommand db (createTableSql {a = Todo}) []
      | Left err => pure (Left err)
    pure (Right ()))
    | Left err => closePool pool >> putStrLn (displayError err) >> exitFailure
  st <- Data.IORef.newIORef (MkTestState 0 [])
  let repo = pooledTodoRepository pool
  repositoryBehaviorChecks st (buildApp repo)
  committed <- withPooledTransactionRepos pool pgTodoRepository (\tx => do
    Right todo <- tx.crud.insert (MkNewTodo "committed" False)
      | Left err => pure (Left err)
    tx.toggle todo.id)
  check st "pooled transaction commits multiple repository operations"
    (case committed of Right (Just todo) => todo.done; _ => False)
  rolledBack <- withPooledTransactionRepos pool pgTodoRepository (\tx => do
    Right _ <- tx.crud.insert (MkNewTodo "rolled back" False)
      | Left err => pure (Left err)
    pure (the (Either PGError ()) (Left (ConnectionError "intentional rollback"))))
  check st "pooled transaction propagates callback failure"
    (case rolledBack of Left _ => True; _ => False)
  persisted <- withConnectionIO pool (\db => queryRows db
    "SELECT title FROM todos WHERE title IN ('committed', 'rolled back') ORDER BY title" [])
  check st "a subsequent lease observes commit and no rolled-back row"
    (case persisted of Right [row] => getText row "title" == Right "committed"; _ => False)
  closePool pool
  closed <- poolClosed pool
  check st "pooled scenario closes every connection" closed
  report st
