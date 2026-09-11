||| Iris.Widget.TUI.Table
||| Bordered data table widget.
module Iris.Widget.TUI.Table

import Iris.Backend.Terminal.Types
import Iris.Widget.TUI.Core
import Iris.Widget.TUI.Primitives

-- ─── Local helpers ───────────────────────────────────────────────────────────

tblRep : Nat -> c -> List c
tblRep Z     _ = []
tblRep (S n) x = x :: tblRep n x

tblDrop : Nat -> List x -> List x
tblDrop Z     xs        = xs
tblDrop _     []        = []
tblDrop (S n) (_ :: xs) = tblDrop n xs

tblTake : Nat -> List x -> List x
tblTake Z     _         = []
tblTake _     []        = []
tblTake (S n) (x :: xs) = x :: tblTake n xs

tblZip : List x -> List y -> List (x, y)
tblZip []       _        = []
tblZip _        []       = []
tblZip (x::xs) (y::ys)  = (x,y) :: tblZip xs ys

tblIota : Nat -> List Nat
tblIota Z     = []
tblIota (S n) = tblIota n ++ [n]

-- ─── Column ──────────────────────────────────────────────────────────────────

public export
data ColAlign = ColLeft | ColCenter | ColRight

public export
record Column where
  constructor MkColumn
  header : String
  width  : Nat
  align  : ColAlign

public export
col : String -> Nat -> Column
col h w = MkColumn h w ColLeft

public export
colRight : String -> Nat -> Column
colRight h w = MkColumn h w ColRight

-- ─── Cell padding ────────────────────────────────────────────────────────────

padRight : Nat -> String -> String
padRight n s =
  let l = length s
  in if l >= n then s else s ++ pack (tblRep (n `minus` l) ' ')

padLeft : Nat -> String -> String
padLeft n s =
  let l = length s
  in if l >= n then s else pack (tblRep (n `minus` l) ' ') ++ s

centerPad : Nat -> String -> String
centerPad n s =
  let l    = length s
  in if l >= n then s
     else let pad = n `minus` l
              lft = cast {to=Nat} (cast {to=Int} pad `div` 2)
              rgt = pad `minus` lft
          in pack (tblRep lft ' ') ++ s ++ pack (tblRep rgt ' ')

alignCell : Column -> String -> String
alignCell c s =
  case c.align of
    ColLeft   => padRight c.width s
    ColRight  => padLeft  c.width s
    ColCenter => centerPad c.width s

-- ─── TableConfig / TableState ────────────────────────────────────────────────

public export
record TableConfig where
  constructor MkTableConfig
  props       : TUIProps
  columns     : List Column
  showHeader  : Bool
  selectedFg  : TermColor
  selectedBg  : TermColor
  headerStyle : CellStyle

public export
defaultTableConfig : TUIProps -> List Column -> TableConfig
defaultTableConfig p cs =
  MkTableConfig p cs True (Color16 0) (Color16 6) boldStyle

public export
record TableState where
  constructor MkTableState
  selectedRow  : Nat
  scrollOffset : Nat

public export
initTableState : TableState
initTableState = MkTableState 0 0

public export
tableUp : Nat -> TableState -> TableState
tableUp count st =
  { selectedRow := if st.selectedRow == 0
                     then count `minus` 1
                     else st.selectedRow `minus` 1 } st

public export
tableDown : Nat -> TableState -> TableState
tableDown count st =
  { selectedRow := cast {to=Nat}
      ((cast {to=Int} st.selectedRow + 1) `mod` cast {to=Int} count) } st

-- ─── Row type ────────────────────────────────────────────────────────────────

public export
Row : Type
Row = List String

-- ─── Widget ──────────────────────────────────────────────────────────────────

||| Render a data table.
public export
tuiTable : TableConfig -> TableState -> List Row -> TUIWidget msg
tuiTable cfg st rows =
  TBox cfg.props (headerWidgets ++ rowWidgets)
  where
    renderCell : Column -> String -> TUIWidget msg
    renderCell c s =
      TText (sized c.width 1 cfg.props) (alignCell c s)

    renderRow : Nat -> Row -> TUIWidget msg
    renderRow i cells =
      let isSel = (st.scrollOffset + i) == st.selectedRow
          rfg   = if isSel then cfg.selectedFg else cfg.props.fg
          rbg   = if isSel then cfg.selectedBg else cfg.props.bg
          rp    = withFg rfg (withBg rbg
                    (at (cfg.props.col + 1) (cfg.props.row + 1 + i) cfg.props))
          txt   = concatMap (\(c, s) => alignCell c s) (tblZip cfg.columns cells)
      in TText rp txt

    headerRow : TUIWidget msg
    headerRow =
      let hp  = withBold (at (cfg.props.col + 1) (cfg.props.row + 1) cfg.props)
          txt = concatMap (\c => padRight c.width c.header) cfg.columns
      in TText hp txt

    headerWidgets : List (TUIWidget msg)
    headerWidgets = if cfg.showHeader then [headerRow] else []

    visibleRows : List Row
    visibleRows = tblTake cfg.props.height (tblDrop st.scrollOffset rows)

    rowWidgets : List (TUIWidget msg)
    rowWidgets = map (uncurry renderRow) (tblZip (tblIota (length visibleRows)) visibleRows)
