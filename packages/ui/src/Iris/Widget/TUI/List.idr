||| Iris.Widget.TUI.List
||| Scrollable, selectable list widget.
module Iris.Widget.TUI.List

import Iris.Backend.Terminal.Types
import Iris.Widget.TUI.Core
import Iris.Widget.TUI.Primitives

-- ─── Local helpers ───────────────────────────────────────────────────────────

lstDrop : Nat -> List x -> List x
lstDrop Z     xs        = xs
lstDrop _     []        = []
lstDrop (S n) (_ :: xs) = lstDrop n xs

lstTake : Nat -> List x -> List x
lstTake Z     _         = []
lstTake _     []        = []
lstTake (S n) (x :: xs) = x :: lstTake n xs

lstNatMod : Nat -> Nat -> Nat
lstNatMod _ Z     = 0
lstNatMod n (S m) = cast {to=Nat} (cast {to=Int} n `mod` cast {to=Int} (S m))

-- ─── ListItem ────────────────────────────────────────────────────────────────

public export
record ListItem (msg : Type) where
  constructor MkListItem
  label      : String
  annotation : Maybe String
  onActivate : Maybe msg
  disabled   : Bool

public export
item : String -> msg -> ListItem msg
item l m = MkListItem l Nothing (Just m) False

public export
itemAnnotated : String -> String -> msg -> ListItem msg
itemAnnotated l a m = MkListItem l (Just a) (Just m) False

public export
itemDisabled : String -> ListItem msg
itemDisabled l = MkListItem l Nothing Nothing True

-- ─── ListState ───────────────────────────────────────────────────────────────

public export
record ListState where
  constructor MkListState
  selectedIndex : Nat
  scrollOffset  : Nat

public export
initListState : ListState
initListState = MkListState 0 0

public export
listUp : Nat -> ListState -> ListState
listUp count st =
  { selectedIndex := if st.selectedIndex == 0
                       then count `minus` 1
                       else st.selectedIndex `minus` 1 } st

public export
listDown : Nat -> ListState -> ListState
listDown count st =
  let newIdx = cast {to=Nat}
        ((cast {to=Int} st.selectedIndex + 1) `mod` cast {to=Int} count)
  in { selectedIndex := newIdx } st

public export
listSelected : ListState -> List (ListItem msg) -> Maybe (ListItem msg)
listSelected st items = go st.selectedIndex items
  where
    go : Nat -> List (ListItem msg) -> Maybe (ListItem msg)
    go _     []        = Nothing
    go Z     (x :: _)  = Just x
    go (S n) (_ :: xs) = go n xs

-- ─── ListMsg ─────────────────────────────────────────────────────────────────

public export
data ListMsg = ListMoveUp | ListMoveDown | ListActivate | ListPageUp | ListPageDown

-- ─── ListConfig ──────────────────────────────────────────────────────────────

public export
record ListConfig where
  constructor MkListConfig
  props          : TUIProps
  selectedFg     : TermColor
  selectedBg     : TermColor
  selectedStyle  : CellStyle
  disabledFg     : TermColor
  selectedPrefix : String
  normalPrefix   : String
  showScrollbar  : Bool

public export
defaultListConfig : TUIProps -> ListConfig
defaultListConfig p = MkListConfig
  { props          = p
  , selectedFg     = Color16 0
  , selectedBg     = Color16 6
  , selectedStyle  = boldStyle
  , disabledFg     = Color16 8
  , selectedPrefix = "> "
  , normalPrefix   = "  "
  , showScrollbar  = True
  }

-- ─── Widget ──────────────────────────────────────────────────────────────────

||| Render a scrollable list.
public export
tuiList : ListConfig -> ListState -> List (ListItem msg) -> TUIWidget msg
tuiList cfg st items =
  TBox cfg.props (zipWithRow 0 visible)
  where
    visible : List (ListItem msg)
    visible = lstTake cfg.props.height (lstDrop st.scrollOffset items)

    makeRow : Nat -> ListItem msg -> TUIWidget msg
    makeRow i li =
      let absIdx = st.scrollOffset + i
          isSel  = absIdx == st.selectedIndex
          pre    = if isSel then cfg.selectedPrefix else cfg.normalPrefix
          rfg    = if isSel then cfg.selectedFg
                   else (if li.disabled then cfg.disabledFg else cfg.props.fg)
          rbg    = if isSel then cfg.selectedBg else cfg.props.bg
          rc     = cfg.props.col + 1
          rr     = cfg.props.row + 1 + i
          rp     = withFg rfg (withBg rbg (at rc rr cfg.props))
      in TText rp (pre ++ li.label)

    zipWithRow : Nat -> List (ListItem msg) -> List (TUIWidget msg)
    zipWithRow _ []        = []
    zipWithRow i (x :: xs) = makeRow i x :: zipWithRow (i + 1) xs
