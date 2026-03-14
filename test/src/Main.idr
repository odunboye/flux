module Main

import TestRouter
import TestJSON
import TestMiddleware
import TestLogging
import System

%default total

reportTest : (String, Bool) -> IO ()
reportTest (name, True) = putStrLn ("  [PASS] " ++ name)
reportTest (name, False) = putStrLn ("  [FAIL] " ++ name)

printResults : List (String, Bool) -> Nat -> Nat -> IO ()
printResults tests passed failed = do
  putStrLn ""
  putStrLn "========================================"
  putStrLn "           TEST RESULTS"
  putStrLn "========================================"
  putStrLn ""
  traverse_ reportTest tests
  putStrLn ""
  putStrLn "========================================"
  putStrLn ("Total: " ++ show (passed + failed) ++ " | Passed: " ++ show passed ++ " | Failed: " ++ show failed)
  putStrLn "========================================"

runTests : List (String, Bool) -> IO ()
runTests tests = printResults tests (length (filter snd tests)) (length (filter (not . snd) tests))

runAllSuites : IO ()
runAllSuites = do
  putStrLn ""
  putStrLn "=== Running Router Tests ==="
  runTests TestRouter.runAllTests
  putStrLn ""
  putStrLn "=== Running JSON Tests ==="
  runTests TestJSON.runAllTests
  putStrLn ""
  putStrLn "=== Running Middleware Tests ==="
  runTests TestMiddleware.runAllTests
  putStrLn ""
  putStrLn "=== Running Logging Tests ==="
  runTests TestLogging.runAllTests

allPassed : Bool
allPassed =
  all snd TestRouter.runAllTests &&
  all snd TestJSON.runAllTests &&
  all snd TestMiddleware.runAllTests &&
  all snd TestLogging.runAllTests

covering
main : IO ()
main = do
  putStrLn ""
  putStrLn "FLUX FRAMEWORK TEST SUITE"
  putStrLn "========================="
  putStrLn ""
  runAllSuites
  if allPassed
    then do
      putStrLn "All tests passed!"
      exitSuccess
    else do
      putStrLn "Some tests failed!"
      exitFailure
