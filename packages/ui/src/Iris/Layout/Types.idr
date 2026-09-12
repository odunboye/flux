||| Iris.Layout.Types
||| Core types for the two-pass layout engine (measure → place).
module Iris.Layout.Types

import Iris.Core.Types

-- ─── Constraints ───────────────────────────────────────────────────────────

||| The min/max bounds a parent imposes on a child during the measure pass.
||| The 0-quantified fields carry compile-time proofs that are erased at
||| runtime — they cost nothing but prevent invalid constraint records.
public export
record Constraints where
  constructor MkConstraints
  minWidth  : Px
  maxWidth  : Px
  minHeight : Px
  maxHeight : Px
  -- 0 wOk : minWidth  <= maxWidth   -- TODO: enable when proof automation ready
  -- 0 hOk : minHeight <= maxHeight

||| Unconstrained — child may be any size.
public export
unconstrained : Constraints
unconstrained = MkConstraints 0 (1.0/0) 0 (1.0/0)
-- Note: 1.0/0 = Infinity in IEEE 754

||| Tight constraint — child must be exactly this size.
public export
tight : Size -> Constraints
tight s = MkConstraints s.width s.width s.height s.height

||| Loose constraint — child may be at most this size, no minimum.
public export
loose : Size -> Constraints
loose s = MkConstraints 0 s.width 0 s.height

-- ─── Layout result ─────────────────────────────────────────────────────────

||| The size a widget reports back to its parent after measuring.
public export
record MeasuredSize where
  constructor MkMeasuredSize
  size     : Size
  baseline : Maybe Px   -- optional text baseline for alignment

-- ─── Positioned widget ─────────────────────────────────────────────────────

||| A widget that has been assigned its final screen rectangle.
public export
record PositionedBox where
  constructor MkPositionedBox
  rect   : Rect
  zIndex : Int

-- ─── Flex properties ───────────────────────────────────────────────────────

public export
data FlexDirection = Row | RowReverse | Column | ColumnReverse

public export
data JustifyContent
  = JustifyStart | JustifyEnd | JustifyCenter
  | SpaceBetween | SpaceAround | SpaceEvenly

public export
data AlignItems
  = AlignStart | AlignEnd | AlignCenter | AlignStretch | AlignBaseline

public export
data FlexWrap = NoWrap | Wrap | WrapReverse

public export
record FlexConfig where
  constructor MkFlexConfig
  direction      : FlexDirection
  justifyContent : JustifyContent
  alignItems     : AlignItems
  wrap           : FlexWrap
  gap            : Px
  rowGap         : Px
  columnGap      : Px
