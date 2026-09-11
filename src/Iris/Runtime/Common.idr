||| Shared runtime primitives for IrisApp backends.
module Iris.Runtime.Common

import Data.IORef
import Iris.State.TEA
import Iris.App

public export
execCmd : Cmd outMsg -> (outMsg -> IO ()) -> IORef Bool -> IO ()
execCmd None             _    _       = pure ()
execCmd (Batch cs)       send quitRef = traverse_ (\c => execCmd c send quitRef) cs
execCmd (MapCmd f c)     send quitRef = execCmd c (send . f) quitRef
execCmd (Task io)        send _       = io >>= send
execCmd (StreamTask act) send _       = act send
execCmd QuitApp          _    quitRef = writeIORef quitRef True

public export
dispatch : IrisApp mdl outMsg -> IORef mdl -> IORef Bool -> outMsg -> IO ()
dispatch app modelRef quitRef msg = do
  m <- readIORef modelRef
  let (m', cmd) = app.update msg m
  writeIORef modelRef m'
  execCmd cmd (dispatch app modelRef quitRef) quitRef
