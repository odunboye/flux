||| Iris.Widget.TUI.Chart
||| Sparkline, bar chart, and dot-plot widgets.
module Iris.Widget.TUI.Chart

import Iris.Backend.Terminal.Types
import Iris.Widget.TUI.Core
import Iris.Widget.TUI.Primitives

-- ─── Local helpers ───────────────────────────────────────────────────────────

chartDrop : Nat -> List v -> List v
chartDrop Z     xs        = xs
chartDrop _     []        = []
chartDrop (S n) (_ :: xs) = chartDrop n xs

-- ─── Block characters ────────────────────────────────────────────────────────

blockChars : List Char
blockChars = [' ', '\x2581', '\x2582', '\x2583', '\x2584',
                   '\x2585', '\x2586', '\x2587', '\x2588']

blockChar : Double -> Char
blockChar ratio =
  let idx    = cast {to=Nat} (ratio * 8.0)
      capped = if idx > 8 then 8 else idx
  in case chartDrop capped blockChars of
       (c :: _) => c
       []       => '\x2588'

-- ─── Sparkline ───────────────────────────────────────────────────────────────

public export
record SparklineConfig where
  constructor MkSparklineConfig
  props : TUIProps
  fg    : TermColor

public export
defaultSparklineConfig : TUIProps -> SparklineConfig
defaultSparklineConfig p = MkSparklineConfig p (Color16 2)

||| Build a sparkline string from data.
public export
sparklineString : List Double -> String
sparklineString [] = ""
sparklineString xs@(_ :: _) =
  let lo  = foldl min (hd xs) xs
      hi  = foldl max (hd xs) xs
      rng = if hi == lo then 1.0 else hi - lo
  in pack (map (\x => blockChar ((x - lo) / rng)) xs)
  where
    hd : List Double -> Double
    hd (x :: _) = x
    hd []       = 0.0

||| Render a sparkline.
public export
tuiSparkline : SparklineConfig -> List Double -> TUIWidget msg
tuiSparkline cfg dataPoints =
  TText (withFg cfg.fg cfg.props) (sparklineString dataPoints)

-- ─── Bar chart ───────────────────────────────────────────────────────────────

public export
record BarItem where
  constructor MkBarItem
  label : String
  value : Double
  color : TermColor

public export
barItem : String -> Double -> BarItem
barItem l v = MkBarItem l v (Color16 2)

public export
record BarChartConfig where
  constructor MkBarChartConfig
  props : TUIProps

public export
defaultBarChartConfig : TUIProps -> BarChartConfig
defaultBarChartConfig p = MkBarChartConfig p

||| Render a bar chart (simplified: sparkline of values for Phase 0).
public export
tuiBarChart : BarChartConfig -> List BarItem -> TUIWidget msg
tuiBarChart cfg bars =
  tuiSparkline (defaultSparklineConfig cfg.props) (map (\b => b.value) bars)

-- ─── Dot plot ────────────────────────────────────────────────────────────────

public export
record DotPlotConfig where
  constructor MkDotPlotConfig
  props : TUIProps
  fg    : TermColor

public export
defaultDotPlotConfig : TUIProps -> DotPlotConfig
defaultDotPlotConfig p = MkDotPlotConfig p (Color16 6)

||| Render a dot plot (placeholder for Phase 0).
public export
tuiDotPlot : DotPlotConfig -> List (Double, Double) -> TUIWidget msg
tuiDotPlot cfg points =
  TText cfg.props ("* " ++ show (length points) ++ " pts")
