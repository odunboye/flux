||| Iris.Widget.TUI.Primitives
||| Core TUI widget constructors.
||| All functions return TUIWidget msg (not the abstract Widget msg).
module Iris.Widget.TUI.Primitives

import Iris.Backend.Terminal.Types
import Iris.Widget.TUI.Core

-- Re-export TUIProps and helpers so callers only import this module.
public export
TUIProps'   : Type
TUIProps'   = TUIProps

-- ─── Text ────────────────────────────────────────────────────────────────────

||| Single-line text at a fixed position.
public export
tuiText : String -> TUIProps -> TUIWidget msg
tuiText = flip TText

-- ─── Box / panel ─────────────────────────────────────────────────────────────

||| Rectangular panel (optionally bordered + titled) with children.
public export
tuiBox : TUIProps -> List (TUIWidget msg) -> TUIWidget msg
tuiBox = TBox

-- ─── Paragraph ───────────────────────────────────────────────────────────────

||| Multi-line text.  Each line becomes a TText at row+i.
public export
tuiParagraph : String -> TUIProps -> TUIWidget msg
tuiParagraph text props =
  TVBox props (zipWithIdx (lines text))
  where
    zipWithIdx : List String -> List (TUIWidget msg)
    zipWithIdx ls =
      let go : Nat -> List String -> List (TUIWidget msg)
          go _ []        = []
          go i (s :: ss) =
            TText (at props.col (props.row + i) props) s :: go (i + 1) ss
      in go 0 ls

    lines : String -> List String
    lines s = splitOn '\n' (unpack s) []
      where
        splitOn : Char -> List Char -> List Char -> List String
        splitOn _ []        acc = [pack (reverse acc)]
        splitOn d (c :: cs) acc =
          if c == d then pack (reverse acc) :: splitOn d cs []
          else splitOn d cs (c :: acc)

-- ─── Horizontal / vertical layout ────────────────────────────────────────────

||| Lay children out side by side (children use their own absolute positions).
public export
tuiHBox : TUIProps -> List (TUIWidget msg) -> TUIWidget msg
tuiHBox = THBox

||| Lay children out top to bottom (children use their own absolute positions).
public export
tuiVBox : TUIProps -> List (TUIWidget msg) -> TUIWidget msg
tuiVBox = TVBox

-- ─── Spacer ──────────────────────────────────────────────────────────────────

||| Blank filler widget (renders nothing).
public export
tuiSpacer : TUIWidget msg
tuiSpacer = tuiEmpty

-- ─── Overlay ─────────────────────────────────────────────────────────────────

||| Render children at the same position; later children draw on top.
public export
tuiOverlay : List (TUIWidget msg) -> TUIWidget msg
tuiOverlay = TVBox defaultTUI

-- ─── Horizontal rule ─────────────────────────────────────────────────────────

||| A horizontal line of `n` dashes at the given position.
public export
tuiHRule : Nat -> TUIProps -> TUIWidget msg
tuiHRule n props =
  tuiText (pack (listRep n '\x2500')) props
  where
    listRep : Nat -> c -> List c
    listRep Z     _ = []
    listRep (S k) x = x :: listRep k x
