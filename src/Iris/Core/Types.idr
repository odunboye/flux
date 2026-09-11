||| Iris.Core.Types
||| Fundamental geometric and colour primitives shared across all layers.
module Iris.Core.Types

-- ─── Numeric aliases ───────────────────────────────────────────────────────

||| A double-precision floating-point pixel value.
public export
Px : Type
Px = Double

-- ─── Geometry ──────────────────────────────────────────────────────────────

||| A 2-D point.
public export
record Point where
  constructor MkPoint
  x : Px
  y : Px

||| An axis-aligned 2-D size.
public export
record Size where
  constructor MkSize
  width  : Px
  height : Px

||| An axis-aligned rectangle (origin + size).
public export
record Rect where
  constructor MkRect
  origin : Point
  size   : Size

||| Edge insets (CSS-style: top / right / bottom / left).
public export
record EdgeInsets where
  constructor MkEdgeInsets
  top    : Px
  right  : Px
  bottom : Px
  left   : Px

public export
allEdges : Px -> EdgeInsets
allEdges v = MkEdgeInsets v v v v

public export
symmetricEdges : (h : Px) -> (v : Px) -> EdgeInsets
symmetricEdges h v = MkEdgeInsets v h v h

-- ─── Colour ────────────────────────────────────────────────────────────────

||| An sRGB colour with a pre-multiplied alpha channel (0.0 – 1.0).
public export
record Color where
  constructor MkColor
  r : Double
  g : Double
  b : Double
  a : Double

public export
rgba : Double -> Double -> Double -> Double -> Color
rgba = MkColor

public export
rgb : Double -> Double -> Double -> Color
rgb r g b = MkColor r g b 1.0

public export
transparent : Color
transparent = MkColor 0 0 0 0

public export
black : Color
black = rgb 0 0 0

public export
white : Color
white = rgb 1 1 1

-- ─── Text alignment ────────────────────────────────────────────────────────

public export
data TextAlign = AlignLeft | AlignCenter | AlignRight | AlignJustify

-- ─── Axis / Direction ──────────────────────────────────────────────────────

public export
data Axis = Horizontal | Vertical

public export
data TextDirection = LTR | RTL

-- ─── Platform tag ──────────────────────────────────────────────────────────

||| Compile-time platform identifier. Used as a phantom type index.
||| Named PlatformTarget to avoid collision with Iris.Platform.Interface.Platform.
public export
data PlatformTarget = Web | Desktop | Mobile | Embedded
