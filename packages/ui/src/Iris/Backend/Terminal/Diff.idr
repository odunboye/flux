||| Iris.Backend.Terminal.Diff
||| Double-buffer cell differ.
||| Compares old CellBuffer vs new, emits only ANSI for changed cells.
module Iris.Backend.Terminal.Diff

import Iris.Backend.Terminal.Types
import Iris.Backend.Terminal.ANSI

-- ─── Nat helpers ────────────────────────────────────────────────────────────

diffNatRange : Nat -> List Nat
diffNatRange Z     = []
diffNatRange (S n) = diffNatRange n ++ [n]

diffNatDiv : Nat -> Nat -> Nat
diffNatDiv n Z     = 0
diffNatDiv n (S d) = cast {to=Nat} (cast {to=Int} n `div` cast {to=Int} (S d))

diffNatMod : Nat -> Nat -> Nat
diffNatMod n Z     = 0
diffNatMod n (S d) = cast {to=Nat} (cast {to=Int} n `mod` cast {to=Int} (S d))

-- ─── Cell equality ──────────────────────────────────────────────────────────

colorEq : TermColor -> TermColor -> Bool
colorEq Default          Default          = True
colorEq (Color16 a)      (Color16 b)      = a == b
colorEq (Color256 a)     (Color256 b)     = a == b
colorEq (ColorRGB r1 g1 b1) (ColorRGB r2 g2 b2) =
  r1 == r2 && g1 == g2 && b1 == b2
colorEq _                _                = False

styleEq : CellStyle -> CellStyle -> Bool
styleEq a b =
  a.bold == b.bold && a.dim == b.dim
  && a.italic == b.italic && a.underline == b.underline
  && a.blink == b.blink && a.reversed == b.reversed
  && a.strikethrough == b.strikethrough

cellEq : Cell -> Cell -> Bool
cellEq a b =
  a.char == b.char
  && colorEq a.fg b.fg
  && colorEq a.bg b.bg
  && styleEq a.style b.style

-- ─── Indexed cell list ──────────────────────────────────────────────────────

indexedCells : CellBuffer -> List (Nat, Nat, Cell)
indexedCells buf =
  let sz    = buf.cols * buf.rows
      idxs  = diffNatRange sz
  in map (\i => ( diffNatMod i buf.cols
               , diffNatDiv i buf.cols
               , getCell buf (diffNatMod i buf.cols) (diffNatDiv i buf.cols)
               )) idxs

-- ─── Diff ───────────────────────────────────────────────────────────────────

||| Compare two CellBuffers; emit ANSI only for changed cells.
public export
diffBuffers : CellBuffer -> CellBuffer -> String
diffBuffers old new =
  let oldCells = indexedCells old
      newCells = indexedCells new
  in concatMap renderIfChanged (pairUp oldCells newCells)
  where
    pairUp : List (Nat, Nat, Cell) -> List (Nat, Nat, Cell)
           -> List ((Nat, Nat, Cell), (Nat, Nat, Cell))
    pairUp []             _              = []
    pairUp _              []             = []
    pairUp (x :: xs)      (y :: ys)      = (x, y) :: pairUp xs ys

    renderIfChanged : ((Nat, Nat, Cell), (Nat, Nat, Cell)) -> String
    renderIfChanged ((c, r, oldCell), (_, _, newCell)) =
      if cellEq oldCell newCell then ""
      else renderCell c r newCell

-- ─── Full redraw ────────────────────────────────────────────────────────────

||| Render the entire buffer unconditionally (first frame or after resize).
public export
fullRedraw : CellBuffer -> String
fullRedraw buf =
  clearScreen ++ concatMap renderOne (indexedCells buf)
  where
    renderOne : (Nat, Nat, Cell) -> String
    renderOne (c, r, cell) = renderCell c r cell
