||| Tests for flux-docker, against a real local Docker daemon (no
||| mock - matches this whole ecosystem's convention, see flux-postgres's
||| own test suite). Uses a small, fast image (busybox), not Postgres -
||| this library's own tests are deliberately decoupled from any
||| particular consumer's use case.
module Main

import Docker
import Data.IORef
import System

%default covering

testContainerName : String
testContainerName = "flux-docker-test-container"

testSpec : ContainerSpec
testSpec = MkContainerSpec
  testContainerName
  "busybox"
  []
  [(28765, 80)]
  -- busybox exits immediately with no command, so give it something
  -- long-running to actually stay up long enough to inspect/stop/start.

record TestState where
  constructor MkTestState
  passed : Nat
  failed : List String

check : Data.IORef.IORef TestState -> String -> Bool -> IO ()
check st name ok = do
  if ok
     then do
       putStrLn "  [PASS] \{name}"
       Data.IORef.modifyIORef st (\s => { passed := S s.passed } s)
     else do
       putStrLn "  [FAIL] \{name}"
       Data.IORef.modifyIORef st (\s => { failed := name :: s.failed } s)

-- `docker run` needs an explicit long-running command for an image like
-- busybox, whose own default entrypoint just exits - `ContainerSpec`
-- has no field for extra args (deliberately, per the README), so this
-- test builds the `docker run` invocation for the long-running variant
-- directly rather than going through `Docker.run`, and only exercises
-- `Docker.run` itself against an image that's *already* long-running by
-- default (postgres, in real usage - here, `busybox sleep` via a raw
-- `docker run ... busybox sleep 300`, invoked the same way `Docker.run`
-- itself would, just with the extra trailing args this library doesn't
-- expose).
runLongLivedTestContainer : IO (Either Int ())
runLongLivedTestContainer = do
  code <- System.Escaped.system
    [ "docker", "run", "-d", "--name", testContainerName
    , "-p", "28765:80"
    , "busybox", "sleep", "300"
    ]
  pure (if code == 0 then Right () else Left code)

covering
scenario : Data.IORef.IORef TestState -> IO ()
scenario st = do
  let go = check st

  avail <- available
  go "available: docker is reachable in this environment" avail

  s0 <- inspect testContainerName
  go "inspect: nonexistent container is NotFound" (s0 == NotFound)

  Right () <- runLongLivedTestContainer
    | Left code => go "run: starts a long-lived container" False
  go "run: starts a long-lived container" True

  s1 <- inspect testContainerName
  go "inspect: running container is Running" (s1 == Running)

  mport <- publishedPort testContainerName 80
  go "publishedPort: reports the mapped host port" (mport == Just 28765)

  Right () <- stop testContainerName
    | Left _ => go "stop: succeeds" False
  go "stop: succeeds" True

  s2 <- inspect testContainerName
  go "inspect: stopped container is Stopped" (s2 == Stopped)

  -- ensureRunning on a Stopped container should start it (not create a
  -- new one, and not error).
  Right () <- ensureRunning testSpec
    | Left _ => go "ensureRunning: starts a stopped container" False
  go "ensureRunning: starts a stopped container" True

  s3 <- inspect testContainerName
  go "inspect: ensureRunning left it Running" (s3 == Running)

  -- ensureRunning on an already-Running container is a no-op (not an
  -- error, doesn't try to re-run/re-create).
  Right () <- ensureRunning testSpec
    | Left _ => go "ensureRunning: no-op when already running" False
  go "ensureRunning: no-op when already running" True

  Right () <- remove testContainerName
    | Left _ => go "remove: succeeds" False
  go "remove: succeeds" True

  s4 <- inspect testContainerName
  go "inspect: removed container is NotFound again" (s4 == NotFound)

covering
main : IO ()
main = do
  avail <- available
  if not avail
     then do
       putStrLn "Docker isn't available in this environment - skipping (nothing to test)."
       exitSuccess
     else do
       -- Clean slate: a leftover container from a previous failed run
       -- shouldn't make this run's results meaningless.
       _ <- remove testContainerName
       st <- Data.IORef.newIORef (MkTestState 0 [])
       scenario st
       -- Always clean up, pass or fail.
       _ <- remove testContainerName
       final <- Data.IORef.readIORef st
       let totalCount = final.passed + length final.failed
       putStrLn "\n========================================"
       putStrLn "Total: \{show totalCount} | Passed: \{show final.passed} | Failed: \{show (length final.failed)}"
       putStrLn "========================================"
       case final.failed of
         [] => putStrLn "All tests passed!"
         fs => do
           putStrLn "Failed: \{show (reverse fs)}"
           exitFailure
