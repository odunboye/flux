||| Iris.Backend.Terminal.Renderer
||| Pure ANSI renderer: TUIWidget msg -> String.
|||
||| There is no IO here.  The renderer traverses the widget tree and builds
||| one big String of ANSI escape sequences.  The runtime writes it to
||| stdout in a single call so the screen updates atomically.
module Iris.Backend.Terminal.Renderer

import Iris.Backend.Terminal.Types
import Iris.Backend.Terminal.ANSI
import Iris.Widget.TUI.Core

-- ─── Local helpers ────────────────────────────────────────────────────────────

rnReplicate : Nat -> c -> List c
rnReplicate Z     _ = []
rnReplicate (S n) x = x :: rnReplicate n x

rnTake : Nat -> List c -> List c
rnTake Z     _         = []
rnTake _     []        = []
rnTake (S n) (x :: xs) = x :: rnTake n xs

-- ─── Colour conversion ───────────────────────────────────────────────────────

-- Iris Color (0-1 Double) → nearest TermColor (truecolor)
irisColorToTerm : Iris.Backend.Terminal.Types.TermColor -> String
irisColorToTerm c = fgColor c   -- already TermColor; just emit it

-- ─── Border rendering ─────────────────────────────────────────────────────────

-- Build a horizontal run of `n` copies of char `c`
hRun : Nat -> Char -> String
hRun n c = pack (rnReplicate n c)

-- Clip or pad a string to exactly `n` chars
clipPad : Nat -> String -> String
clipPad n s =
  let chars = rnTake n (unpack s)
      pad   = n `minus` length chars
  in pack chars ++ pack (rnReplicate pad ' ')

renderBorder : TUIProps -> String
renderBorder props =
  case props.border of
    Nothing => ""
    Just bc =>
      let c = props.col
          r = props.row
          w = props.width
          h = props.height
          -- top row
          topInner = w `minus` 2
          topBar   = case props.title of
                       Nothing => hRun topInner bc.horizontal
                       Just t  =>
                         let ti = " " ++ t ++ " "
                             tl = length ti
                         in if tl >= topInner
                              then hRun topInner bc.horizontal
                              else ti ++ hRun (topInner `minus` tl) bc.horizontal
          top    = moveCursor c r
                ++ resetAttrs
                ++ fgColor props.fg ++ bgColor props.bg
                ++ pack [bc.topLeft] ++ topBar ++ pack [bc.topRight]
          -- side rows
          sides  = concatMap (\i =>
                     moveCursor c (r + i)
                  ++ fgColor props.fg ++ bgColor props.bg
                  ++ pack [bc.vertical]
                  ++ pack (rnReplicate (w `minus` 2) ' ')
                  ++ pack [bc.vertical])
                   (sideRows 1 (h `minus` 1))
          -- bottom row
          bot    = moveCursor c (r + h `minus` 1)
                ++ fgColor props.fg ++ bgColor props.bg
                ++ pack [bc.bottomLeft]
                ++ hRun (w `minus` 2) bc.horizontal
                ++ pack [bc.bottomRight]
      in top ++ sides ++ bot ++ resetAttrs
  where
    sideRows : Nat -> Nat -> List Nat
    sideRows lo hi =
      if lo >= hi then []
      else lo :: sideRows (lo + 1) hi

-- ─── Text rendering ──────────────────────────────────────────────────────────

renderText : TUIProps -> String -> String
renderText props text =
  let display = if props.width == 0 then text
                else clipPad props.width text
  in moveCursor props.col props.row
  ++ resetAttrs
  ++ fgColor props.fg
  ++ bgColor props.bg
  ++ styleCode props.style
  ++ display
  ++ resetAttrs

-- ─── Widget renderer ─────────────────────────────────────────────────────────

||| Render a TUIWidget to an ANSI string.
||| Concatenate the result with clearScreen ++ cursorHome before writing.
public export
renderWidget : TUIWidget msg -> String
renderWidget (TText props text)    = renderText props text
renderWidget (TBox props children) =
  renderBorder props ++ concatMap renderWidget children
renderWidget (THBox _ children)    = concatMap renderWidget children
renderWidget (TVBox _ children)    = concatMap renderWidget children
renderWidget (TMap _ w)            = renderWidget w

-- ─── Full frame ──────────────────────────────────────────────────────────────

||| Build a complete frame string: clear + home + widget tree + reset.
public export
renderFrame : TUIWidget msg -> String
renderFrame w = clearScreen ++ cursorHome ++ renderWidget w ++ resetAttrs
