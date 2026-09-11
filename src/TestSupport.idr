module TestSupport

import Flux.Async.Core
import Flux.Async.Runner
import System

%default covering

export
runTestTask : Task es a -> IO (Outcome es a)
runTestTask action = do
  Right result <- runTask action | Left err => do
    putStrLn ("FAIL runtime startup: " ++ err)
    exitFailure
  pure result
