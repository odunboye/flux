||| Shared runtime primitives for IrisApp backends.
module Iris.Runtime.Common

import Data.IORef
import Iris.State.TEA
import Iris.App

private
sendUnlessQuit : IORef Bool -> (msg -> IO ()) -> msg -> IO ()
sendUnlessQuit quitRef send msg = do
  quit <- readIORef quitRef
  when (not quit) (send msg)

||| Execute a command while respecting application shutdown. A batch stops at
||| its first `QuitApp`; asynchronous and streaming callbacks are guarded both
||| before starting and whenever they attempt to deliver a message.
public export
execCmd : Cmd outMsg -> (outMsg -> IO ()) -> IORef Bool -> IO ()
execCmd command send quitRef = do
  quit <- readIORef quitRef
  when (not quit) $
    case command of
      None => pure ()
      Batch commands =>
        foldl (\previous, next => previous >> execCmd next send quitRef)
              (pure ()) commands
      MapCmd f nested => execCmd nested (sendUnlessQuit quitRef send . f) quitRef
      Task action => action >>= sendUnlessQuit quitRef send
      StreamTask action => action (sendUnlessQuit quitRef send)
      QuitApp => writeIORef quitRef True

||| Apply a message only while the application is alive. This check belongs in
||| the shared dispatcher as command callbacks may race with backend teardown.
public export
dispatch : IrisApp mdl outMsg -> IORef mdl -> IORef Bool -> outMsg -> IO ()
dispatch app modelRef quitRef msg = do
  quit <- readIORef quitRef
  when (not quit) $ do
    m <- readIORef modelRef
    let (m', cmd) = app.update msg m
    writeIORef modelRef m'
    execCmd cmd (dispatch app modelRef quitRef) quitRef
