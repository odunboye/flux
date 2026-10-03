||| Shared runtime primitives for UIApp backends.
module Flux.UI.Runtime.Common

import Data.IORef
import Flux.UI.State.TEA
import Flux.UI.App

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
      CancellableTask start => ignore (start (sendUnlessQuit quitRef send))
      QuitApp => writeIORef quitRef True

||| Apply a message only while the application is alive. This check belongs in
||| the shared dispatcher as command callbacks may race with backend teardown.
public export
dispatch : UIApp mdl outMsg -> IORef mdl -> IORef Bool -> outMsg -> IO ()
dispatch app modelRef quitRef msg = do
  quit <- readIORef quitRef
  when (not quit) $ do
    m <- readIORef modelRef
    let (m', cmd) = app.update msg m
    writeIORef modelRef m'
    execCmd cmd (dispatch app modelRef quitRef) quitRef

||| Shared lifecycle state for backends that support cooperative cancellation.
public export
record RuntimeControl where
  constructor MkRuntimeControl
  quit          : IORef Bool
  paused        : IORef Bool
  generation    : IORef Nat
  cancellations : IORef (List (IO ()))

public export
newRuntimeControl : IORef Bool -> IO RuntimeControl
newRuntimeControl quitRef = do
  pausedRef <- newIORef False
  generationRef <- newIORef 0
  cancellationRef <- newIORef []
  pure (MkRuntimeControl quitRef pausedRef generationRef cancellationRef)

public export
cancelActiveEffects : RuntimeControl -> IO ()
cancelActiveEffects control = do
  actions <- readIORef control.cancellations
  writeIORef control.cancellations []
  modifyIORef control.generation S
  sequence_ actions

public export
suspendRuntime : RuntimeControl -> IO ()
suspendRuntime control = do
  writeIORef control.paused True
  cancelActiveEffects control

public export
resumeRuntime : RuntimeControl -> IO ()
resumeRuntime control = writeIORef control.paused False

managedSend : RuntimeControl -> Nat -> (msg -> IO ()) -> msg -> IO ()
managedSend control expected send message = do
  quit <- readIORef control.quit
  paused <- readIORef control.paused
  current <- readIORef control.generation
  when (not quit && not paused && current == expected) (send message)

||| Execute effects with cancellation registration and stale-generation guards.
public export
execCmdManaged : Cmd msg -> (msg -> IO ()) -> RuntimeControl -> IO ()
execCmdManaged command send control = do
  quit <- readIORef control.quit
  paused <- readIORef control.paused
  when (not quit && not paused) $ do
    generation <- readIORef control.generation
    let guarded = managedSend control generation send
    case command of
      None => pure ()
      Batch commands => traverse_ (\next => execCmdManaged next send control) commands
      MapCmd f nested => execCmdManaged nested (guarded . f) control
      Task action => action >>= guarded
      StreamTask action => action guarded
      CancellableTask start => do
        cancel <- start guarded
        -- A synchronous callback may quit or suspend before start returns.
        -- Ownership of the returned cleanup must still be discharged.
        stopped <- readIORef control.quit
        suspended <- readIORef control.paused
        current <- readIORef control.generation
        if stopped || suspended || current /= generation
          then cancel
          else modifyIORef control.cancellations (cancel ::)
      QuitApp => do
        writeIORef control.quit True
        cancelActiveEffects control

public export
dispatchManaged : UIApp model msg -> IORef model -> RuntimeControl -> msg -> IO ()
dispatchManaged app modelRef control message = do
  quit <- readIORef control.quit
  when (not quit) $ do
    model <- readIORef modelRef
    let (next, command) = app.update message model
    writeIORef modelRef next
    execCmdManaged command (dispatchManaged app modelRef control) control
