module Main

import TodoApi
import DevPostgres
import System
import Config
import Models

import Nebula.Pool

covering
main : IO ()
main = do
  cfg <- loadConfig
  putStrLn "Connecting to Postgres at \{cfg.host}:\{show cfg.port}/\{cfg.database} ..."
  Right db <- ensureLocalPostgres cfg
    | Left err => do
        putStrLn "Failed to connect to Postgres: \{displayError err}"
        exitFailure
  Right _ <- execCommand db (createTableSql {a = Todo}) []
    | Left err => do
        putStrLn "Failed to initialize schema: \{displayError err}"
        exitFailure
  putStrLn "Connected. Schema ready."
  closeDB db
  Right pool <- newPool defaultPoolConfig cfg
    | Left err => putStrLn (displayError err) >> exitFailure
  let repo := pooledTodoRepository pool
  args <- getArgs
  case args of
    _ :: t => runProg (runServerArgs (runApp (buildApp repo)) t)
    []     => runProg (runServerArgs (runApp (buildApp repo)) [])
  closePool pool
