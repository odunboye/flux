module Main

import TestRouter
import TestHTTP
import TestHTTPProperties
import TestJSON
import TestMiddleware
import TestLogging
import TestConfig
import TestCookies
import TestSession
import TestStatic
import TestHealth
import System

%default covering

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

-- Runs one suite's already-collected results, printing a report and
-- returning whether everything in it passed.
runTests : String -> List (String, Bool) -> IO Bool
runTests label tests = do
  putStrLn ""
  putStrLn ("=== Running " ++ label ++ " Tests ===")
  printResults tests (length (filter snd tests)) (length (filter (not . snd) tests))
  pure (all snd tests)

main : IO ()
main = do
  putStrLn ""
  putStrLn "FLUX FRAMEWORK TEST SUITE"
  putStrLn "========================="

  routerOk     <- runTests "Router" TestRouter.runAllTests
  httpTests    <- TestHTTP.runAllTests
  httpOk       <- runTests "HTTP" httpTests
  httpPropTests <- TestHTTPProperties.runAllTests
  httpPropOk    <- runTests "HTTP Properties" httpPropTests
  jsonOk       <- runTests "JSON" TestJSON.runAllTests
  loggingOk    <- runTests "Logging" TestLogging.runAllTests
  configTests  <- TestConfig.runAllTests
  configOk     <- runTests "Config" configTests
  middlewareTests <- TestMiddleware.runAllTests
  middlewareOk    <- runTests "Middleware" middlewareTests
  cookiesOk       <- runTests "Cookies" TestCookies.runAllTests
  sessionTests    <- TestSession.runAllTests
  sessionOk       <- runTests "Session" sessionTests
  staticTests     <- TestStatic.runAllTests
  staticOk        <- runTests "Static" staticTests
  healthTests     <- TestHealth.runAllTests
  healthOk        <- runTests "Health" healthTests

  if routerOk && httpOk && httpPropOk && jsonOk && middlewareOk && loggingOk && configOk
     && cookiesOk && sessionOk && staticOk && healthOk
    then do
      putStrLn "All tests passed!"
      exitSuccess
    else do
      putStrLn "Some tests failed!"
      exitFailure
