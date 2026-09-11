module Main

import System
import Data.IORef
import Iris.App
import Iris.Platform.Event
import Iris.Runtime.Common
import Iris.State.TEA
import Iris.Widget

data Msg = Add | Stop

update : Msg -> Nat -> (Nat, Cmd Msg)
update Add model = (S model, none)
update Stop model = (S model, Batch [QuitApp, Task (pure Add)])

app : IrisApp Nat Msg
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

  putStrLn "Runtime tests passed"
