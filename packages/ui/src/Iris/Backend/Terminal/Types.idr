||| Iris.Backend.Terminal.Types
||| Core types for the TUI (terminal) backend.
module Iris.Backend.Terminal.Types

-- ─── Terminal colour ─────────────────────────────────────────────────────────

public export
data TermColor
  = Default
  | Color16  Nat
  | Color256 Nat
  | ColorRGB Bits8 Bits8 Bits8

-- ─── Cell style ──────────────────────────────────────────────────────────────

public export
record CellStyle where
  constructor MkCellStyle
  bold          : Bool
  dim           : Bool
  italic        : Bool
  underline     : Bool
  blink         : Bool
  reversed      : Bool
  strikethrough : Bool

public export
noStyle : CellStyle
noStyle = MkCellStyle False False False False False False False

public export
boldStyle : CellStyle
boldStyle = { bold := True } noStyle

-- ─── Cell ────────────────────────────────────────────────────────────────────

public export
record Cell where
  constructor MkCell
  char  : Char
  fg    : TermColor
  bg    : TermColor
  style : CellStyle

public export
blankCell : Cell
blankCell = MkCell ' ' Default Default noStyle

-- ─── CellBuffer ──────────────────────────────────────────────────────────────

public export
record CellBuffer where
  constructor MkCellBuffer
  cols  : Nat
  rows  : Nat
  cells : List Cell

listReplicate : Nat -> a -> List a
listReplicate Z     _ = []
listReplicate (S n) x = x :: listReplicate n x

listIndex : List a -> Nat -> Maybe a
listIndex []        _     = Nothing
listIndex (x :: _)  Z     = Just x
listIndex (_ :: xs) (S n) = listIndex xs n

listUpdateAt : Nat -> (a -> a) -> List a -> List a
listUpdateAt _     _ []        = []
listUpdateAt Z     f (x :: xs) = f x :: xs
listUpdateAt (S n) f (x :: xs) = x :: listUpdateAt n f xs

public export
emptyBuffer : Nat -> Nat -> CellBuffer
emptyBuffer c r = MkCellBuffer c r (listReplicate (c * r) blankCell)

public export
getCell : CellBuffer -> Nat -> Nat -> Cell
getCell buf c r =
  case listIndex buf.cells (r * buf.cols + c) of
    Just cell => cell
    Nothing   => blankCell

public export
setCell : CellBuffer -> Nat -> Nat -> Cell -> CellBuffer
setCell buf c r cell =
  { cells $= listUpdateAt (r * buf.cols + c) (const cell) } buf

-- ─── Terminal size ────────────────────────────────────────────────────────────

public export
record TermSize where
  constructor MkTermSize
  cols : Nat
  rows : Nat

-- ─── Border chars ────────────────────────────────────────────────────────────

public export
record BorderChars where
  constructor MkBorderChars
  topLeft     : Char
  topRight    : Char
  bottomLeft  : Char
  bottomRight : Char
  horizontal  : Char
  vertical    : Char
  tTop        : Char
  tBottom     : Char
  tLeft       : Char
  tRight      : Char
  cross       : Char

public export
thinBorder : BorderChars
thinBorder = MkBorderChars '\x250c' '\x2510' '\x2514' '\x2518'
                            '\x2500' '\x2502'
                            '\x252c' '\x2534' '\x251c' '\x2524' '\x253c'

public export
doubleBorder : BorderChars
doubleBorder = MkBorderChars '\x2554' '\x2557' '\x255a' '\x255d'
                              '\x2550' '\x2551'
                              '\x2566' '\x2569' '\x2560' '\x2563' '\x256c'

public export
roundedBorder : BorderChars
roundedBorder = MkBorderChars '\x256d' '\x256e' '\x2570' '\x256f'
                               '\x2500' '\x2502'
                               '\x252c' '\x2534' '\x251c' '\x2524' '\x253c'

public export
asciiBorder : BorderChars
asciiBorder = MkBorderChars '+' '+' '+' '+' '-' '|' '+' '+' '+' '+' '+'

-- ─── Progress chars ──────────────────────────────────────────────────────────

public export
record ProgressChars where
  constructor MkProgressChars
  full  : Char
  empty : Char

public export
blockProgress : ProgressChars
blockProgress = MkProgressChars '\x2588' '\x2591'

public export
asciiProgress : ProgressChars
asciiProgress = MkProgressChars '#' '-'

-- ─── Spinner frames ──────────────────────────────────────────────────────────

public export
SpinnerFrames : Type
SpinnerFrames = List String

public export
dotsSpinner : SpinnerFrames
dotsSpinner = ["\x280b", "\x2819", "\x2839", "\x2838", "\x283c",
               "\x2834", "\x2826", "\x2827", "\x2807", "\x280f"]

public export
lineSpinner : SpinnerFrames
lineSpinner = ["-", "\\", "|", "/"]

public export
arrowSpinner : SpinnerFrames
arrowSpinner = ["\x2190", "\x2196", "\x2191", "\x2197",
                "\x2192", "\x2198", "\x2193", "\x2199"]

public export
pulseSpinner : SpinnerFrames
pulseSpinner = ["\x2588", "\x2593", "\x2592", "\x2591"]

-- ─── TUI widget props ─────────────────────────────────────────────────────────

||| Layout + style for every TUI widget node.
public export
record TUIProps where
  constructor MkTUIProps
  col    : Nat
  row    : Nat
  width  : Nat
  height : Nat
  fg     : TermColor
  bg     : TermColor
  style  : CellStyle
  border : Maybe BorderChars
  title  : Maybe String

public export
defaultTUI : TUIProps
defaultTUI = MkTUIProps 0 0 0 0 Default Default noStyle Nothing Nothing

setBoldStyle : CellStyle -> CellStyle
setBoldStyle s = MkCellStyle True s.dim s.italic s.underline s.blink s.reversed s.strikethrough

public export
at : Nat -> Nat -> TUIProps -> TUIProps
at c r p = { col := c, row := r } p

public export
sized : Nat -> Nat -> TUIProps -> TUIProps
sized w h p = { width := w, height := h } p

public export
withFg : TermColor -> TUIProps -> TUIProps
withFg c p = { fg := c } p

public export
withBg : TermColor -> TUIProps -> TUIProps
withBg c p = { bg := c } p

public export
withBold : TUIProps -> TUIProps
withBold p = { style $= setBoldStyle } p

public export
withBorder : BorderChars -> TUIProps -> TUIProps
withBorder bc p = { border := Just bc } p

public export
withTitle : String -> TUIProps -> TUIProps
withTitle t p = { title := Just t } p
