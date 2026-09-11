||| Iris.Theme.Types
||| Design-token based theming system.
||| Themes are plain records — no magic, just data.
module Iris.Theme.Types

import Iris.Core.Types

-- ─── Color tokens ──────────────────────────────────────────────────────────

public export
record ColorTokens where
  constructor MkColorTokens
  primary        : Color
  primaryFg      : Color   -- foreground on primary background
  secondary      : Color
  secondaryFg    : Color
  background     : Color
  surface        : Color
  surfaceVariant : Color
  onBackground   : Color
  onSurface      : Color
  error          : Color
  onError        : Color
  outline        : Color
  shadow         : Color

-- ─── Typography tokens ─────────────────────────────────────────────────────

public export
record TypeScale where
  constructor MkTypeScale
  displayLarge  : Double   -- px
  displayMedium : Double
  displaySmall  : Double
  headlineLarge : Double
  headlineMed   : Double
  headlineSmall : Double
  titleLarge    : Double
  titleMed      : Double
  titleSmall    : Double
  bodyLarge     : Double
  bodyMed       : Double
  bodySmall     : Double
  labelLarge    : Double
  labelMed      : Double
  labelSmall    : Double

public export
record TypographyTokens where
  constructor MkTypographyTokens
  fontFamily    : String
  monoFamily    : String
  scale         : TypeScale

-- ─── Spacing scale (4px base grid) ────────────────────────────────────────

public export
record SpacingScale where
  constructor MkSpacingScale
  px0  : Double   --  0
  px1  : Double   --  4
  px2  : Double   --  8
  px3  : Double   -- 12
  px4  : Double   -- 16
  px5  : Double   -- 20
  px6  : Double   -- 24
  px8  : Double   -- 32
  px10 : Double   -- 40
  px12 : Double   -- 48
  px16 : Double   -- 64
  px20 : Double   -- 80
  px24 : Double   -- 96

-- ─── Radii ─────────────────────────────────────────────────────────────────

public export
record RadiiTokens where
  constructor MkRadiiTokens
  none   : Double
  sm     : Double
  md     : Double
  lg     : Double
  xl     : Double
  full   : Double   -- 9999 (pill / circle)

-- ─── Shadows ───────────────────────────────────────────────────────────────

public export
record ShadowLevel where
  constructor MkShadowLevel
  offsetX : Double
  offsetY : Double
  blur    : Double
  spread  : Double
  color   : Color

public export
record ShadowTokens where
  constructor MkShadowTokens
  none : List ShadowLevel
  sm   : List ShadowLevel
  md   : List ShadowLevel
  lg   : List ShadowLevel
  xl   : List ShadowLevel

-- ─── Motion tokens ─────────────────────────────────────────────────────────

public export
record MotionTokens where
  constructor MkMotionTokens
  durationFast    : Double   -- ms
  durationBase    : Double
  durationSlow    : Double
  easingStandard  : String   -- CSS cubic-bezier string for now
  easingDecelerate: String
  easingAccelerate: String

-- ─── Theme ─────────────────────────────────────────────────────────────────

public export
record Theme where
  constructor MkTheme
  name       : String
  dark       : Bool
  colors     : ColorTokens
  typography : TypographyTokens
  spacing    : SpacingScale
  radii      : RadiiTokens
  shadows    : ShadowTokens
  motion     : MotionTokens
