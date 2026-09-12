||| Iris.State.Signal
||| Fine-grained reactive signals — Solid.js style.
||| Signals are used for *local*, high-frequency state that does not need
||| to travel through the TEA update cycle (hover, focus, scroll offset …).
module Iris.State.Signal

import Data.IORef

-- ─── Signal ────────────────────────────────────────────────────────────────

||| A mutable reactive cell.
public export
record Signal (a : Type) where
  constructor MkSignal
  ||| Read the current value (tracking access for derived signals).
  get : IO a
  ||| Write a new value (notifies all derived signals / effects).
  set : a -> IO ()

-- ─── Derived (computed) signal ─────────────────────────────────────────────

||| A read-only signal whose value is computed from other signals.
public export
record Derived (a : Type) where
  constructor MkDerived
  get : IO a

-- ─── Reactive effect ───────────────────────────────────────────────────────

||| An IO action that re-runs whenever any signal it reads changes.
public export
record Effect where
  constructor MkEffect
  ||| Dispose the effect (stop tracking).
  dispose : IO ()

-- ─── Constructors (to be implemented per backend) ──────────────────────────

||| Create a new signal with an initial value.
||| The runtime fills in the IORef + subscriber bookkeeping.
public export
createSignal : a -> IO (Signal a)
createSignal initialValue = do
  ref <- newIORef initialValue
  pure $ MkSignal (readIORef ref) (writeIORef ref)

||| Create a derived signal from a computation.
||| In a full implementation the computation would be tracked so it
||| re-runs only when its dependencies change.
public export
createDerived : IO a -> IO (Derived a)
createDerived compute = pure $ MkDerived compute

||| Run an effect that re-runs on signal changes.
public export
createEffect : IO () -> IO Effect
createEffect action = do
  action
  pure $ MkEffect (pure ())  -- no-op dispose in minimal impl
