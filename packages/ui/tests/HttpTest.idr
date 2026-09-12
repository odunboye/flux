module Main

import System
import Iris.Effect.Http.Web

assert : String -> Bool -> IO ()
assert _ True = pure ()
assert label False = do
  putStrLn ("HTTP test failed: " ++ label)
  exitFailure

main : IO ()
main = do
  assert "bounded exponential backoff"
    (retryDelays (MkRetryPolicy 5 100 500) == [100, 200, 400, 500, 500])
  assert "no retries" (retryDelays (MkRetryPolicy 0 100 500) == [])
  putStrLn "HTTP tests passed"
