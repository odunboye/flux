||| Iris.Animation.Types
||| Animation primitives: Tween, Spring, Timeline.
||| Animations are *values in time* — pure functions from timestamp to value.
module Iris.Animation.Types

-- ─── Easing ────────────────────────────────────────────────────────────────

||| An easing function maps a linear progress t ∈ [0,1] to a curved one.
public export
Easing : Type
Easing = Double -> Double

public export
linear : Easing
linear t = t

public export
easeIn : Easing
easeIn t = t * t

public export
easeOut : Easing
easeOut t = t * (2 - t)

public export
easeInOut : Easing
easeInOut t =
  if t < 0.5 then 2 * t * t
              else -1 + (4 - 2 * t) * t

-- ─── Interpolatable ────────────────────────────────────────────────────────

||| A type that can be linearly interpolated.
public export
interface Lerp a where
  lerp : Double -> a -> a -> a

public export
Lerp Double where
  lerp t a b = a + t * (b - a)

public export
Lerp Int where
  lerp t a b = cast $ the Double $ lerp t (cast a) (cast b)

-- ─── Tween ─────────────────────────────────────────────────────────────────

||| A tween animates a value from `from` to `to` over `duration` ms.
public export
record Tween (a : Type) where
  constructor MkTween
  from     : a
  to       : a
  duration : Double    -- milliseconds
  delay    : Double    -- milliseconds before starting
  easing   : Easing

||| Sample a tween at time t (ms since start including delay).
public export
sampleTween : Lerp a => Tween a -> Double -> a
sampleTween tw t =
  let t' = t - tw.delay
  in if t' <= 0
       then tw.from
       else if t' >= tw.duration
         then tw.to
         else
           let progress = t' / tw.duration
               eased    = tw.easing progress
           in lerp eased tw.from tw.to

-- ─── Spring ────────────────────────────────────────────────────────────────

||| Physics-based spring parameters.
public export
record SpringConfig where
  constructor MkSpring
  stiffness : Double   -- e.g. 170
  damping   : Double   -- e.g. 26
  mass      : Double   -- e.g. 1.0

public export
defaultSpring : SpringConfig
defaultSpring = MkSpring 170 26 1.0

public export
bouncySpring : SpringConfig
bouncySpring = MkSpring 180 12 1.0

-- ─── Timeline ──────────────────────────────────────────────────────────────

||| A sequence or parallel composition of animations.
public export
data Timeline : (a : Type) -> Type where
  ||| A single tween.
  Single   : Tween a -> Timeline a
  ||| Run two timelines sequentially (second starts when first ends).
  Sequence : Timeline a -> Timeline a -> Timeline a
  ||| Run two timelines in parallel (both start at t=0).
  Parallel : Timeline a -> Timeline a -> Timeline a
  ||| Repeat a timeline n times (Nothing = infinite).
  Repeat   : Maybe Nat -> Timeline a -> Timeline a
  ||| Reverse a timeline.
  Reverse  : Timeline a -> Timeline a

-- ─── Animation state ───────────────────────────────────────────────────────

public export
data AnimState = Running Double | Paused Double | Finished

public export
record Animation (a : Type) where
  constructor MkAnimation
  timeline  : Timeline a
  state     : AnimState
  startTime : Double   -- absolute ms
