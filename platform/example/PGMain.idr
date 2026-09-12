module PGMain

import Protocol
import Config
import Models
import TodoRepository
import Data.PGTable
import Data.PGRepository
import Idris2_pg
import Nebula.PG
import Nebula.Pool
import System

%default covering

createTodo : TodoRepository -> CreateTodoRequest -> AppProg TodoResponse
createTodo repo request = do
  if request.title == "" then throw (MkAppError 400 "Title must not be empty") else do
    todo <- dbIO (repo.crud.insert (MkNewTodo request.title False))
    pure (MkTodoResponse todo.done (show todo.id) todo.title)

main : IO ()
main = do
  cfg <- loadConfig
  Right db <- connectDB cfg
    | Left err => putStrLn (displayError err) >> exitFailure
  created <- execCommand db (createTableSql {a = Todo}) []
  closeDB db
  case created of
    Left err => putStrLn (displayError err) >> exitFailure
    Right _ => pure ()
  Right pool <- newPool defaultPoolConfig cfg
    | Left err => putStrLn (displayError err) >> exitFailure
  let repo = pooledTodoRepository pool
  let application = app |> useAlways corsAllowAll |> withErrorRenderer rpcErrorRenderer
                        |> withRoutes (routes (MkApi (createTodo repo)))
  args <- getArgs
  runProg (runServerArgs (runApp application) (drop 1 args))
  closePool pool
