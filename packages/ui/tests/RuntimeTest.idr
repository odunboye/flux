module Main

import System
import Data.IORef
import Flux.UI.App
import Flux.UI.Platform.Event
import Flux.UI.Runtime.Common
import Flux.UI.State.TEA
import Flux.UI.Widget

data Msg = Add | Stop

update : Msg -> Nat -> (Nat, Cmd Msg)
update Add model = (S model, none)
update Stop model = (S model, Batch [QuitApp, Task (pure Add)])

app : UIApp Nat Msg
app = MkApp (0, none) update (\n => text (show n)) (\_, _ => Nothing) Nothing

assert : String -> Bool -> IO ()
assert _ True = pure ()
assert label False = do
  putStrLn ("Runtime test failed: " ++ label)
  exitFailure

main : IO ()
main = do
  model <- newIORef 0
  quit <- newIORef False

  dispatch app model quit Add
  first <- readIORef model
  assert "normal dispatch" (first == 1)

  dispatch app model quit Stop
  stopped <- readIORef model
  didQuit <- readIORef quit
  assert "QuitApp marks runtime stopped" didQuit
  assert "batch stops after QuitApp" (stopped == 2)

  dispatch app model quit Add
  afterLateEvent <- readIORef model
  assert "events after shutdown are ignored" (afterLateEvent == 2)

  execCmd (Task (pure Add)) (dispatch app model quit) quit
  afterLateCommand <- readIORef model
  assert "commands after shutdown are ignored" (afterLateCommand == 2)

  managedModel <- newIORef 0
  managedQuit <- newIORef False
  control <- newRuntimeControl managedQuit
  cancelled <- newIORef 0
  callback <- newIORef (\_ => pure ())
  let managed = CancellableTask (\send => do
        writeIORef callback send
        pure (modifyIORef cancelled S))
  execCmdManaged managed (dispatchManaged app managedModel control) control
  suspendRuntime control
  cancelCount <- readIORef cancelled
  assert "suspension cancels active effects" (cancelCount == 1)
  resumeRuntime control
  stale <- readIORef callback
  stale Add
  staleModel <- readIORef managedModel
  assert "pre-pause callback is stale after resume" (staleModel == 0)

  execCmdManaged managed (dispatchManaged app managedModel control) control
  fresh <- readIORef callback
  fresh Add
  freshModel <- readIORef managedModel
  assert "current generation callback dispatches" (freshModel == 1)
  dispatchManaged app managedModel control Stop
  managedDidQuit <- readIORef managedQuit
  assert "managed update can quit" managedDidQuit
  finalCancelCount <- readIORef cancelled
  assert "shutdown cancels active effects" (finalCancelCount == 2)

  putStrLn "Runtime tests passed"
