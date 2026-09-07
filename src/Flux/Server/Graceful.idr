module Flux.Server.Graceful

-- NOTE: this module is not yet wired into `flux.ipkg`'s `modules` list and
-- is not exported from `Flux`. It predates the Context/Handler rework and
-- has known issues (the `ShutdownManager` field types don't typecheck as
-- written, and `setupSignalHandler` is a documented placeholder even
-- though `async-posix` ships real POSIX signal handling via
-- `IO.Async.Signal`). Fixing it and wiring it into `HTTP.serveWith`'s
-- accept loop is tracked as a follow-up milestone, not part of this pass.

import public System
import public IO.Async
import public IO.Async.Loop.Posix

%default total

-- Shutdown signal types
public export
data ShutdownSignal
  = SigTerm    -- SIGTERM: Termination signal
  | SigInt     -- SIGINT: Interrupt (Ctrl+C)
  | SigHup     -- SIGHUP: Hangup/reload config
  | UserRequest -- Programmatic shutdown

export
Show ShutdownSignal where
  showPrec _ SigTerm = "SIGTERM"
  showPrec _ SigInt = "SIGINT"
  showPrec _ SigHup = "SIGHUP"
  showPrec _ UserRequest = "UserRequest"

-- Shutdown state
public export
data ShutdownState
  = Running
  | ShuttingDown String  -- Reason for shutdown
  | Shutdown

export
Eq ShutdownState where
  Running == Running = True
  ShuttingDown x == ShuttingDown y = x == y
  Shutdown == Shutdown = True
  _ == _ = False

-- Graceful shutdown manager
public export
data ShutdownManager = MkShutdownManager (IO Ref ShutdownState) (IO Ref (List (ShutdownSignal -> IO ()))) (IO Ref Nat)

export
newShutdownManager : IO ShutdownManager
newShutdownManager = do
  st <- new Ref Running
  ls <- new Ref []
  ac <- new Ref 0
  pure (MkShutdownManager st ls ac)

-- Increment active connection count
export
connectionOpened : ShutdownManager -> IO ()
connectionOpened (MkShutdownManager _ _ ac) = modify ac (+ 1)

-- Decrement active connection count
export
connectionClosed : ShutdownManager -> IO ()
connectionClosed (MkShutdownManager _ _ ac) = modify ac (\n => if n > 0 then n - 1 else 0)

-- Get active connection count
export
activeConnections : ShutdownManager -> IO Nat
activeConnections (MkShutdownManager _ _ ac) = read ac

-- Get current shutdown state
export
getState : ShutdownManager -> IO ShutdownState
getState (MkShutdownManager st _ _) = read st

-- Check if shutting down
export
isShuttingDown : ShutdownManager -> IO Bool
isShuttingDown mgr = do
  s <- getState mgr
  pure (case s of
    ShuttingDown _ => True
    Shutdown => True
    _ => False)

-- Register shutdown listener
export
onShutdown : ShutdownManager -> (ShutdownSignal -> IO ()) -> IO ()
onShutdown (MkShutdownManager _ ls _) callback = do
  ls' <- read ls
  write ls (callback :: ls')

-- Notify all listeners of shutdown
notifyListeners : ShutdownManager -> ShutdownSignal -> IO ()
notifyListeners (MkShutdownManager _ ls _) signal = do
  ls <- read ls
  traverse_ (\cb => cb signal) ls

-- Initiate graceful shutdown
export
shutdown : ShutdownManager -> ShutdownSignal -> IO ()
shutdown mgr@(MkShutdownManager st _ _) signal = do
  currentState <- getState mgr
  case currentState of
    ShuttingDown _ => pure ()  -- Already shutting down
    Shutdown => pure ()         -- Already shutdown
    Running => do
      let reason = "Received " ++ show signal
      write st (ShuttingDown reason)
      putStrLn "[Graceful] Starting shutdown: \{reason}"
      notifyListeners mgr signal

      -- Wait for active connections to drain
      waitForConnections mgr

      write st Shutdown
      putStrLn "[Graceful] Shutdown complete"

where
  waitForConnections : ShutdownManager -> IO ()
  waitForConnections mgr = do
    count <- activeConnections mgr
    if count > 0
      then do
        putStrLn "[Graceful] Waiting for \{show count} active connections..."
        pure ()
      else
        pure ()

-- Signal handler for POSIX signals
export
setupSignalHandler : ShutdownManager -> IO ()
setupSignalHandler mgr = do
  -- Note: Actual signal handling requires foreign function calls
  -- This is a placeholder for the actual implementation
  putStrLn "[Graceful] Signal handlers registered (placeholder)"

  -- In production, you would use:
  -- - Foreign imports for signal() or sigaction()
  -- - Or use a library like posix-signals

  -- For now, register a simple shutdown listener
  onShutdown mgr handleSignal

where
  handleSignal : ShutdownSignal -> IO ()
  handleSignal SigTerm = putStrLn "[Graceful] Handling SIGTERM"
  handleSignal SigInt = putStrLn "[Graceful] Handling SIGINT"
  handleSignal SigHup = putStrLn "[Graceful] Handling SIGHUP (reload config)"
  handleSignal UserRequest = pure ()

-- Run an action with graceful shutdown support
export
withGracefulShutdown : ShutdownManager -> IO a -> IO (Either String a)
withGracefulShutdown mgr action = do
  connectionOpened mgr
  result <- action
  connectionClosed mgr
  pure (Right result)

-- Run server with graceful shutdown
export
runWithShutdown : ShutdownManager -> IO () -> IO ()
runWithShutdown mgr serverAction = do
  setupSignalHandler mgr

  -- Run server in background
  _ <- fork serverAction
  pure ()

-- Shutdown timeout in milliseconds
export
defaultShutdownTimeout : Integer
defaultShutdownTimeout = 30000  -- 30 seconds
