||| Flux.UI.State.TEA
||| The Elm Architecture (TEA) — the primary state-management model for Flux UI.
|||
||| Pure:   Model, View, Update
||| Impure: Cmd (outbound effects), Sub (inbound subscriptions)
module Flux.UI.State.TEA

-- Private dependency for the compatibility App record below.
-- Supported applications import Flux.UI.App.UIApp and Flux.UI.Widget.
import Flux.UI.Core.Widget

-- ─── Cmd ───────────────────────────────────────────────────────────────────

||| A `Cmd msg` is an *opaque description* of a side-effect that, when
||| executed by the runtime, eventually produces zero or more `msg` values.
||| Cmds are *data*, not IO actions — the runtime decides when to run them.
public export
data Cmd : (msg : Type) -> Type where
  ||| Do nothing.
  None    : Cmd msg
  ||| Run a batch of commands concurrently.
  Batch   : List (Cmd msg) -> Cmd msg
  ||| Map the resulting message through a function.
  MapCmd  : (a -> b) -> Cmd a -> Cmd b
  ||| A single raw IO action that produces a message.
  ||| Smart constructors in Flux.UI.Effect.* wrap this.
  Task    : IO msg -> Cmd msg
  ||| A streaming task: calls `send` zero or more times.
  ||| Use this for LLM token streaming, file tailing, etc.
  StreamTask : ((msg -> IO ()) -> IO ()) -> Cmd msg
  ||| Start cooperative asynchronous work and return its cancellation action.
  ||| Supported runners invoke this on shutdown; DOM/Canvas also do so on
  ||| lifecycle suspension. Starters must return promptly after arranging work.
  CancellableTask : ((msg -> IO ()) -> IO (IO ())) -> Cmd msg
  ||| Tell the runtime to exit cleanly.
  ||| Use `quit` in your update function instead of returning `none`.
  QuitApp : Cmd msg

public export
Functor Cmd where
  map f None               = None
  map f (Batch cs)         = Batch (map (map f) cs)
  map f (MapCmd g c)       = MapCmd (f . g) c
  map f (Task io)          = Task (map f io)
  map f (StreamTask act)   = StreamTask (\send => act (send . f))
  map f (CancellableTask act) = CancellableTask (\send => act (send . f))
  map _ QuitApp            = QuitApp

public export
none : Cmd msg
none = None

public export
batch : List (Cmd msg) -> Cmd msg
batch = Batch

||| Command that exits the application cleanly.
public export
quit : Cmd msg
quit = QuitApp

-- ─── Sub ───────────────────────────────────────────────────────────────────

||| A `Sub msg` is an *ongoing subscription* to an external event source
||| (timer ticks, window resize, WebSocket messages, …).
public export
data Sub : (msg : Type) -> Type where
  NoSub    : Sub msg
  BatchSub : List (Sub msg) -> Sub msg
  MapSub   : (a -> b) -> Sub a -> Sub b
  ||| Register a listener; the IO action is called each time the source fires.
  Listen   : String -> ((msg -> IO ()) -> IO (IO ())) -> Sub msg
  -- The inner IO () is the *unsubscribe* action.

public export
Functor Sub where
  map f NoSub           = NoSub
  map f (BatchSub ss)   = BatchSub (map (map f) ss)
  map f (MapSub g s)    = MapSub (f . g) s
  map f (Listen k reg)  = Listen k (\send => reg (send . f))

public export
noSub : Sub msg
noSub = NoSub

public export
batchSub : List (Sub msg) -> Sub msg
batchSub = BatchSub

-- ─── App ───────────────────────────────────────────────────────────────────

||| Legacy application record for Core.Runtime; not consumed by supported runners.
||| Use Flux.UI.App.UIApp with terminal, DOM or Canvas runners.
|||
||| @model  The application state type.
||| @msg    The message type (user events + effect results).
public export
record App (model : Type) (msg : Type) where
  constructor MkApp
  ||| Initial model and any startup commands.
  init          : (model, Cmd msg)
  ||| Pure state transition.
  update        : msg -> model -> (model, Cmd msg)
  ||| Pure view — the entire UI derived from the model.
  view          : model -> Widget msg
  ||| Ongoing subscriptions that depend on the current model.
  subscriptions : model -> Sub msg

-- ─── Helpers ───────────────────────────────────────────────────────────────

||| Legacy Core.Runtime helper. New applications use Flux.UI.App.MkApp.
public export
simpleApp : (model, Cmd msg)
          -> (msg -> model -> (model, Cmd msg))
          -> (model -> Widget msg)
          -> App model msg
simpleApp i u v = MkApp i u v (const noSub)
