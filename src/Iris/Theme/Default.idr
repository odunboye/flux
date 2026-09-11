||| Iris.Theme.Default
||| Built-in light and dark themes.
module Iris.Theme.Default

import Iris.Core.Types
import Iris.Theme.Types

-- ─── Default spacing (4px grid) ────────────────────────────────────────────

defaultSpacing : SpacingScale
defaultSpacing = MkSpacingScale 0 4 8 12 16 20 24 32 40 48 64 80 96

-- ─── Default radii ─────────────────────────────────────────────────────────

defaultRadii : RadiiTokens
defaultRadii = MkRadiiTokens 0 4 8 12 16 9999

-- ─── Default motion ────────────────────────────────────────────────────────

defaultMotion : MotionTokens
defaultMotion = MkMotionTokens
  150 300 500
  "cubic-bezier(0.4, 0, 0.2, 1)"
  "cubic-bezier(0, 0, 0.2, 1)"
  "cubic-bezier(0.4, 0, 1, 1)"

-- ─── Default typography ────────────────────────────────────────────────────

defaultTypography : TypographyTokens
defaultTypography = MkTypographyTokens
  { fontFamily   = "system-ui, -apple-system, sans-serif"
  , monoFamily   = "ui-monospace, 'Cascadia Code', monospace"
  , scale        = MkTypeScale
      { displayLarge  = 57
      , displayMedium = 45
      , displaySmall  = 36
      , headlineLarge = 32
      , headlineMed   = 28
      , headlineSmall = 24
      , titleLarge    = 22
      , titleMed      = 16
      , titleSmall    = 14
      , bodyLarge     = 16
      , bodyMed       = 14
      , bodySmall     = 12
      , labelLarge    = 14
      , labelMed      = 12
      , labelSmall    = 11
      }
  }

-- ─── Default shadows ───────────────────────────────────────────────────────

noShadow : List ShadowLevel
noShadow = []

smShadow : List ShadowLevel
smShadow = [ MkShadowLevel 0 1 2 0 (rgba 0 0 0 0.05)
           , MkShadowLevel 0 1 3 0 (rgba 0 0 0 0.10) ]

mdShadow : List ShadowLevel
mdShadow = [ MkShadowLevel 0 4  6 (-1) (rgba 0 0 0 0.07)
           , MkShadowLevel 0 2  4 (-1) (rgba 0 0 0 0.06) ]

lgShadow : List ShadowLevel
lgShadow = [ MkShadowLevel 0 10 15 (-3) (rgba 0 0 0 0.10)
           , MkShadowLevel 0  4  6 (-2) (rgba 0 0 0 0.05) ]

xlShadow : List ShadowLevel
xlShadow = [ MkShadowLevel 0 20 25 (-5)  (rgba 0 0 0 0.10)
           , MkShadowLevel 0  8 10 (-6)  (rgba 0 0 0 0.04) ]

defaultShadows : ShadowTokens
defaultShadows = MkShadowTokens noShadow smShadow mdShadow lgShadow xlShadow

-- ─── Light theme colors ────────────────────────────────────────────────────

lightColors : ColorTokens
lightColors = MkColorTokens
  { primary        = rgb 0.25 0.32 0.71   -- indigo-600
  , primaryFg      = white
  , secondary      = rgb 0.44 0.50 0.56
  , secondaryFg    = white
  , background     = rgb 0.98 0.98 0.99
  , surface        = white
  , surfaceVariant = rgb 0.93 0.93 0.96
  , onBackground   = rgb 0.07 0.07 0.10
  , onSurface      = rgb 0.07 0.07 0.10
  , error          = rgb 0.73 0.11 0.15
  , onError        = white
  , outline        = rgb 0.74 0.74 0.77
  , shadow         = rgba 0 0 0 0.20
  }

-- ─── Dark theme colors ─────────────────────────────────────────────────────

darkColors : ColorTokens
darkColors = MkColorTokens
  { primary        = rgb 0.65 0.70 0.96   -- indigo-300
  , primaryFg      = rgb 0.07 0.09 0.35
  , secondary      = rgb 0.73 0.76 0.80
  , secondaryFg    = rgb 0.07 0.09 0.14
  , background     = rgb 0.07 0.07 0.10
  , surface        = rgb 0.11 0.11 0.15
  , surfaceVariant = rgb 0.16 0.16 0.22
  , onBackground   = rgb 0.93 0.93 0.96
  , onSurface      = rgb 0.93 0.93 0.96
  , error          = rgb 0.93 0.53 0.55
  , onError        = rgb 0.40 0.00 0.05
  , outline        = rgb 0.36 0.36 0.42
  , shadow         = rgba 0 0 0 0.40
  }

-- ─── Exported themes ───────────────────────────────────────────────────────

public export
lightTheme : Theme
lightTheme = MkTheme
  { name       = "iris-light"
  , dark       = False
  , colors     = lightColors
  , typography = defaultTypography
  , spacing    = defaultSpacing
  , radii      = defaultRadii
  , shadows    = defaultShadows
  , motion     = defaultMotion
  }

public export
darkTheme : Theme
darkTheme = MkTheme
  { name       = "iris-dark"
  , dark       = True
  , colors     = darkColors
  , typography = defaultTypography
  , spacing    = defaultSpacing
  , radii      = defaultRadii
  , shadows    = defaultShadows
  , motion     = defaultMotion
  }
