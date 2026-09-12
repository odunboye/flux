||| Iris.Widget.TUI.Progress
||| Progress bar, spinner, and gauge widgets.
module Iris.Widget.TUI.Progress

import Iris.Backend.Terminal.Types
import Iris.Widget.TUI.Core
import Iris.Widget.TUI.Primitives

-- ─── Local helpers ───────────────────────────────────────────────────────────

prgRep : Nat -> c -> List c
prgRep Z     _ = []
prgRep (S n) x = x :: prgRep n x

prgPadLeft : Nat -> String -> String
prgPadLeft n s =
  let len = length s
  in if len >= n then s
     else pack (prgRep (n `minus` len) ' ') ++ s

prgNatMod : Nat -> Nat -> Nat
prgNatMod _ Z     = 0
prgNatMod n (S m) =
  cast {to=Nat} (cast {to=Int} n `mod` cast {to=Int} (S m))

-- ─── Progress bar ────────────────────────────────────────────────────────────

public export
record ProgressConfig where
  constructor MkProgressConfig
  props       : TUIProps
  chars       : ProgressChars
  showPercent : Bool
  label       : Maybe String

public export
defaultProgressConfig : TUIProps -> ProgressConfig
defaultProgressConfig p = MkProgressConfig p blockProgress True Nothing

pctW : Bool -> Nat
pctW True  = 5
pctW False = 0

lblW : Maybe String -> Nat
lblW Nothing  = 0
lblW (Just l) = length l + 1

||| Build the progress string for ratio in [0.0, 1.0].
public export
progressString : ProgressConfig -> Double -> String
progressString cfg ratio =
  let r       = max 0.0 (min 1.0 ratio)
      barW    = (cfg.props.width `minus` pctW cfg.showPercent) `minus` lblW cfg.label
      filled  = cast {to=Nat} (r * cast barW)
      empty   = barW `minus` filled
      bar     = pack (prgRep filled cfg.chars.full)
             ++ pack (prgRep empty  cfg.chars.empty)
      pct     = if cfg.showPercent
                  then " " ++ prgPadLeft 3 (show (cast {to=Int} (r * 100))) ++ "%"
                  else ""
      lbl     = case cfg.label of
                  Nothing => ""
                  Just l  => l ++ " "
  in lbl ++ bar ++ pct

||| Render a progress bar.
public export
tuiProgress : ProgressConfig -> Double -> TUIWidget msg
tuiProgress cfg ratio =
  TText cfg.props (progressString cfg ratio)

-- ─── Spinner ─────────────────────────────────────────────────────────────────

public export
record SpinnerConfig where
  constructor MkSpinnerConfig
  props  : TUIProps
  frames : SpinnerFrames
  label  : Maybe String

public export
defaultSpinnerConfig : TUIProps -> SpinnerConfig
defaultSpinnerConfig p = MkSpinnerConfig p dotsSpinner Nothing

getFrame : Nat -> List String -> String
getFrame _     []        = "?"
getFrame Z     (f :: _)  = f
getFrame (S n) (_ :: fs) = getFrame n fs

||| Render a spinner (tick = frame index, advances each update).
public export
tuiSpinner : SpinnerConfig -> Nat -> TUIWidget msg
tuiSpinner cfg tick =
  let fc      = length cfg.frames
      idx     = if fc == 0 then 0 else prgNatMod tick fc
      frame   = getFrame idx cfg.frames
      display = case cfg.label of
                  Nothing => frame
                  Just l  => frame ++ " " ++ l
  in TText cfg.props display

-- ─── Gauge ───────────────────────────────────────────────────────────────────

public export
record GaugeConfig where
  constructor MkGaugeConfig
  props    : TUIProps
  name     : String
  filledFg : TermColor
  emptyFg  : TermColor

public export
defaultGaugeConfig : TUIProps -> String -> GaugeConfig
defaultGaugeConfig p n = MkGaugeConfig p n (Color16 2) (Color16 8)

prgPadRight : Nat -> String -> String
prgPadRight n s =
  let len = length s
  in if len >= n then s
     else s ++ pack (prgRep (n `minus` len) ' ')

||| Render a labelled gauge.
public export
tuiGauge : GaugeConfig -> Double -> TUIWidget msg
tuiGauge cfg ratio =
  TText cfg.props
    (prgPadRight 8 cfg.name ++ "[" ++ progressString (defaultProgressConfig cfg.props) ratio ++ "]")
