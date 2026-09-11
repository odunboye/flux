||| Iris.Core.Runtime
||| The Iris main loop.
||| Ties together: TEA state, event dispatch, reconciler, and the PAL.
module Iris.Core.Runtime

import Data.IORef
import Iris.Core.Types
import Iris.Core.Widget
import Iris.Core.VTree
import Iris.State.TEA
import Iris.Platform.Interface
import Iris.Platform.Event

-- ─── Runtime state ─────────────────────────────────────────────────────────

||| Internal mutable state held by the runtime.
||| The user never touches this directly.
record RuntimeState (mdl : Type) (msg : Type) where
  constructor MkRuntimeState
  appModel       : mdl
  pendingCmds    : List (Cmd msg)
  activeSubs     : List (Sub msg)
  lastVTree      : Maybe VNode
  frameRequested : Bool

-- ─── Event → Msg dispatch ──────────────────────────────────────────────────

||| Convert a platform event to zero or more application messages.
||| In a full implementation this walks the widget tree hit-testing
||| pointer events and dispatching to the correct widget's handler.
dispatchEvent : Event -> List msg
dispatchEvent _ = []   -- TODO: hit-test widget tree

-- ─── Cmd executor ──────────────────────────────────────────────────────────

||| Execute a Cmd, delivering resulting messages via callback.
executeCmd : Cmd msg -> (msg -> IO ()) -> IO ()
executeCmd None             _    = pure ()
executeCmd (Batch cs)       send = traverse_ (\c => executeCmd c send) cs
executeCmd (MapCmd f c)     send = executeCmd c (send . f)
executeCmd (Task io)        send = do
  result <- io
  send result
executeCmd (StreamTask act) send = act send
executeCmd QuitApp          _    = pure ()   -- runtime exit is handled by TUIApp

-- ─── Step helper ───────────────────────────────────────────────────────────

stepUpdate : App mdl msg
           -> (mdl, List (Cmd msg))
           -> msg
           -> (mdl, List (Cmd msg))
stepUpdate app (m, cmds) msg =
  let (m', cmd) = app.update msg m
  in (m', cmd :: cmds)

-- ─── Frame ─────────────────────────────────────────────────────────────────

||| Run one application frame.
runFrame : App mdl msg
         -> Iris.Platform.Interface.Platform
         -> IORef (RuntimeState mdl msg)
         -> IO ()
runFrame app plat stateRef = do
  st <- readIORef stateRef

  -- 1. Collect events
  events <- plat.input.pollEvents

  -- 2. Dispatch events → messages → update
  let msgs = concatMap dispatchEvent events
  let (newModel, newCmds) = foldl (stepUpdate app) (st.appModel, []) msgs

  -- 3. View (stub — widget tree will feed the reconciler in later phases)
  let _ = app.view newModel

  -- 4. Render
  plat.renderer.beginFrame
  plat.renderer.endFrame

  -- 5. Execute new commands
  traverse_ (\c => executeCmd c (\_ => pure ())) newCmds

  -- 6. Persist new state
  writeIORef stateRef
    (MkRuntimeState newModel newCmds [] Nothing False)

-- ─── Entry point ───────────────────────────────────────────────────────────

||| Launch an Iris application.
||| The platform is responsible for calling `runFrame` every tick.
public export
run : App mdl msg -> Iris.Platform.Interface.Platform -> IO ()
run app plat = do
  let (initModel, initCmd) = app.init
  stateRef <- newIORef
    (MkRuntimeState initModel [initCmd] [] Nothing True)
  runLoop stateRef
  where
    runLoop : IORef (RuntimeState mdl msg) -> IO ()
    runLoop ref = do
      runFrame app plat ref
      runLoop ref
