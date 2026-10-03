||| Flux.UI.Widget
||| Platform-agnostic widget tree — the single source of truth for all
||| UI backends (TUI, Web/DOM, Desktop, Mobile).
|||
||| Design goals
||| ─────────────
||| 1. No terminal-specific concepts (no col/row, no TermColor, no ANSI).
||| 2. No browser-specific concepts (no CSS, no DOM, no HTML).
||| 3. Style is expressed in abstract terms; each backend maps it.
||| 4. Layout is declarative (fill/fixed/hug); backends compute positions.
module Flux.UI.Widget

-- ─── Colour ──────────────────────────────────────────────────────────────────

||| Platform-agnostic colour.
||| Backends map these to ANSI colours, CSS named colours, or GPU colours.
public export
data UIColor
  = Inherit
  | IRGB    Nat Nat Nat   -- 0-255
  | IBlue | IRed | IGreen | IYellow | ICyan | IMagenta
  | IWhite | IBlack | IGray
  | ILightBlue | ILightGreen | ILightRed | ILightYellow
  | IDarkBlue  | IDarkGray

-- ─── Border ──────────────────────────────────────────────────────────────────

public export
data BorderKind = NoBorder | ThinBorder | ThickBorder | RoundedBorder

-- ─── Style ───────────────────────────────────────────────────────────────────

||| Abstract style record.  All fields are optional; backends use defaults
||| for anything that has no representation on their platform.
public export
record Style where
  constructor MkStyle
  fg        : Maybe UIColor
  bg        : Maybe UIColor
  bold      : Bool
  italic    : Bool
  underline : Bool
  border    : BorderKind
  padH      : Nat              -- left+right padding (abstract units)
  padV      : Nat              -- top+bottom padding
  fixedW    : Maybe Nat        -- fixed width  (TUI: cells, Web: chars×~8px)
  fixedH    : Maybe Nat        -- fixed height
  fillH     : Bool             -- stretch to fill available width
  fillV     : Bool             -- stretch to fill available height
  label     : Maybe String     -- box/panel title
  secret    : Bool             -- mask input rendering; never changes edit values

public export
defaultStyle : Style
defaultStyle = MkStyle Nothing Nothing False False False
               NoBorder 0 0 Nothing Nothing False False Nothing False

-- ─── Style helpers ───────────────────────────────────────────────────────────

public export fg     : UIColor -> Style -> Style ; fg     c s = { fg       := Just c } s
public export bg     : UIColor -> Style -> Style ; bg     c s = { bg       := Just c } s
public export sfg    : UIColor -> Style          ; sfg    c   = fg c defaultStyle
public export sbg    : UIColor -> Style          ; sbg    c   = bg c defaultStyle

public export sBold      : Style -> Style ; sBold      s = { bold      := True } s
public export sItalic    : Style -> Style ; sItalic    s = { italic    := True } s
public export sUnderline : Style -> Style ; sUnderline s = { underline := True } s

public export sBorder  : BorderKind -> Style -> Style ; sBorder  b s = { border  := b    } s
public export sTitle   : String     -> Style -> Style ; sTitle   t s = { label   := Just t } s
public export sFixedW  : Nat        -> Style -> Style ; sFixedW  n s = { fixedW  := Just n } s
public export sFixedH  : Nat        -> Style -> Style ; sFixedH  n s = { fixedH  := Just n } s
public export sPadH    : Nat        -> Style -> Style ; sPadH    n s = { padH    := n    } s
public export sPadV    : Nat        -> Style -> Style ; sPadV    n s = { padV    := n    } s
public export sPad     : Nat        -> Style -> Style
sPad n s = { padH := n, padV := n } s

public export
sSecret : Style -> Style
sSecret s = { secret := True } s

public export
inputDisplay : Style -> String -> String
inputDisplay s value = if s.secret then pack (map (const '*') (unpack value)) else value

public export sFillH : Style -> Style ; sFillH s = { fillH := True } s
public export sFillV : Style -> Style ; sFillV s = { fillV := True } s
public export sFill  : Style -> Style ; sFill  s = { fillH := True, fillV := True } s

-- Combine a list of modifiers onto defaultStyle
public export
styled : List (Style -> Style) -> Style
styled = foldl (\s, f => f s) defaultStyle

-- ─── Widget ──────────────────────────────────────────────────────────────────

||| The abstract widget tree.
||| Every UI backend renders this into its own output format.
public export
data Widget : (msg : Type) -> Type where
  -- ── Content ────────────────────────────────────────────────────────────
  ||| Plain text (one line).
  WText     : Style -> String -> Widget msg

  ||| Text that wraps to the available width.
  WWrapText : Style -> String -> Widget msg

  ||| Editable single-line text field.  `value` is the current string.
  WInput    : Style -> (value : String) -> (onChange : String -> msg) -> Widget msg

  ||| Clickable / keyboard-activatable button.
  WButton   : Style -> String -> msg -> Widget msg

  ||| Tick-box.  `onToggle` is sent when the user toggles it.
  WCheckbox : Style -> (checked : Bool) -> (onToggle : msg) -> Widget msg

  -- ── Data visualisation ─────────────────────────────────────────────────
  ||| Progress bar.  `frac ∈ [0,1]`.
  WProgress : Style -> (frac : Double) -> Widget msg

  ||| Braille spinner.  `tick` increments every animation frame.
  WSpinner  : Style -> (tick : Nat) -> Widget msg

  ||| Sparkline (mini bar chart).  Values are in [0,1].
  WSparkline : Style -> List Double -> Widget msg

  -- ── Layout ─────────────────────────────────────────────────────────────
  ||| Vertical stack (top-to-bottom).
  WVStack   : Style -> List (Widget msg) -> Widget msg

  ||| Horizontal stack (left-to-right).
  WHStack   : Style -> List (Widget msg) -> Widget msg

  ||| Empty flexible spacer — fills remaining space.
  WSpacer   : Widget msg

  ||| Full-width horizontal rule / divider.
  WDivider  : Style -> Widget msg

  ||| Clipped scroll viewport with logical cell offsets.
  WScroll   : Style -> (scrollX : Nat) -> (scrollY : Nat) -> Widget msg -> Widget msg

-- ─── Functor ─────────────────────────────────────────────────────────────────

public export
Functor Widget where
  map f (WText   s t)           = WText   s t
  map f (WWrapText s t)         = WWrapText s t
  map f (WInput  s v h)         = WInput  s v (f . h)
  map f (WButton s t m)         = WButton s t (f m)
  map f (WCheckbox s c m)       = WCheckbox s c (f m)
  map f (WProgress  s p)        = WProgress  s p
  map f (WSpinner   s t)        = WSpinner   s t
  map f (WSparkline s vs)       = WSparkline s vs
  map f (WVStack s cs)          = WVStack s (map (map f) cs)
  map f (WHStack s cs)          = WHStack s (map (map f) cs)
  map f WSpacer                 = WSpacer
  map f (WDivider s)            = WDivider s
  map f (WScroll s x y child)   = WScroll s x y (map f child)

-- ─── Smart constructors (no-style variants) ──────────────────────────────────

public export text     : String -> Widget msg ; text     = WText defaultStyle
public export wrappedText : String -> Widget msg ; wrappedText = WWrapText defaultStyle
public export spacer   : Widget msg           ; spacer   = WSpacer
public export divider  : Widget msg           ; divider  = WDivider defaultStyle

public export
vstack : List (Widget msg) -> Widget msg
vstack = WVStack defaultStyle

public export
hstack : List (Widget msg) -> Widget msg
hstack = WHStack defaultStyle

public export
progress : Double -> Widget msg
progress = WProgress defaultStyle

public export
spinner : Nat -> Widget msg
spinner = WSpinner defaultStyle

public export
sparkline : List Double -> Widget msg
sparkline = WSparkline defaultStyle

public export
checkbox : Bool -> msg -> Widget msg
checkbox = WCheckbox defaultStyle

public export
button : String -> msg -> Widget msg
button = WButton defaultStyle

public export
input : String -> (String -> msg) -> Widget msg
input = WInput defaultStyle

public export
scrollView : Nat -> Nat -> Widget msg -> Widget msg
scrollView = WScroll defaultStyle
