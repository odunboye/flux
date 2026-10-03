module Main

import System
import Data.Maybe
import Data.IORef
import System.Concurrency
import Flux.UI.Runtime.Common
import Flux.UI.State.TEA
import Flux.UI.Backend.Terminal.Run as Terminal

%default covering

assert : String -> Bool -> IO ()
assert _ True = pure ()
assert label False = putStrLn ("Terminal runtime failed: " ++ label) >> exitFailure

main : IO ()
main = do
  quitRef <- newIORef False
  control <- newRuntimeControl quitRef
  cancelled <- newIORef 0
  messages <- newIORef (the (List Nat) [])
  callback <- newIORef (\_ => pure ())
  let send = \message => modifyIORef messages (message ::)
  let effect : Cmd Nat = CancellableTask (\deliver => do
        writeIORef callback deliver
        deliver 1
        pure (modifyIORef cancelled S >> deliver 99))
  Terminal.execCmd (MapCmd S effect) send control
  initial <- readIORef messages
  assert "mapped callback arrives before quit" (initial == [2])
  cancellations <- readIORef control.cancellations
  assert "cooperative cleanup registered before command returns" (length cancellations == 1)
  startedAfterQuit <- newIORef False
  Terminal.execCmd (Batch [QuitApp, CancellableTask (\_ => do
    writeIORef startedAfterQuit True
    pure (pure ()))]) send control
  late <- readIORef callback
  late 3
  after <- readIORef messages
  count <- readIORef cancelled
  extra <- readIORef startedAfterQuit
  assert "quit cancels once" (count == 1)
  assert "callbacks during/after cancellation are discarded" (after == [2])
  assert "batch commands after quit never start" (not extra)
  Terminal.execCmd QuitApp send control
  cancelActiveEffects control
  repeated <- readIORef cancelled
  assert "repeated shutdown does not repeat cleanup" (repeated == 1)
  runningQuit <- newIORef False
  running <- newRuntimeControl runningQuit
  results <- makeChannel {a = Nat}
  Terminal.execCmd (Task (pure 7)) (channelPut results) running
  normal <- channelGet results
  assert "raw Task still delivers asynchronously" (normal == 7)

  started <- makeChannel {a = ()}
  release <- makeChannel {a = ()}
  finished <- makeChannel {a = ()}
  Terminal.execCmd (StreamTask (\deliver => do
    channelPut started ()
    channelGet release
    deliver 99
    channelPut finished ())) (channelPut results) running
  channelGet started
  Terminal.execCmd QuitApp (channelPut results) running
  channelPut release ()
  channelGet finished
  lateResult <- channelGetNonBlocking results
  assert "raw streaming callback after quit is discarded" (isNothing lateResult)

  putStrLn "Terminal runtime tests passed"
