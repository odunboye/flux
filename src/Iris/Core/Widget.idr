||| Iris.Core.Widget
||| The Widget type: an immutable description of a piece of UI.
||| Widgets are cheap to construct; the runtime holds all mutable state.
module Iris.Core.Widget

import Iris.Core.Types

-- ─── Widget node metadata ──────────────────────────────────────────────────

||| Every widget carries a bag of properties that the layout / paint phases
||| can inspect without knowing the concrete widget kind.
public export
record WidgetMeta where
  constructor MkWidgetMeta
  key     : Maybe String    -- diff hint for the reconciler
  testId  : Maybe String    -- for widget testing
  -- extend with aria props, style ref, etc.

public export
defaultMeta : WidgetMeta
defaultMeta = MkWidgetMeta Nothing Nothing

-- ─── Widget ────────────────────────────────────────────────────────────────

||| The core Widget type.
|||
||| @msg  The message type produced by user interaction.
|||
||| A Widget is a *pure description* — it carries no mutable state.
||| The Iris runtime wraps each widget in an Element (stateful identity)
||| and eventually a RenderObject (layout + paint).
||| Deprecated compatibility type; use `Iris.Widget.Widget` for supported applications.
public export
data Widget : (msg : Type) -> Type where

  ||| A leaf widget (no children). The concrete widget data lives in the
  ||| node record injected by smart constructors (text, image, …).
  Leaf : WidgetMeta -> Widget msg

  ||| A widget with an ordered list of children (box, row, column, …).
  Node : WidgetMeta -> List (Widget msg) -> Widget msg

  ||| Attach a stable string key so the reconciler can match this widget
  ||| across re-renders even when its position in the list changes.
  Keyed : String -> Widget msg -> Widget msg

  ||| Suspend evaluation of the subtree until the runtime decides it is
  ||| dirty. Equivalent to React.memo / Flutter's const constructor.
  Suspend : Lazy (Widget msg) -> Widget msg

  ||| Render this widget outside its natural position in the tree
  ||| (e.g. modals, tooltips, dropdowns).
  Portal : Widget msg -> Widget msg

  ||| Functor map — lift a message transformer into the widget tree.
  ||| This is how child components communicate with parents.
  Map : {0 msgA, msgB : Type} -> (msgA -> msgB) -> Widget msgA -> Widget msgB

-- ─── Functor ───────────────────────────────────────────────────────────────

public export
Functor Widget where
  map f (Leaf m)      = Leaf m
  map f (Node m cs)   = Node m (map (map f) cs)
  map f (Keyed k w)   = Keyed k (map f w)
  map f (Suspend w)   = Suspend (map f w)
  map f (Portal w)    = Portal (map f w)
  map f (Map g w)     = Map (f . g) w

-- ─── Helpers ───────────────────────────────────────────────────────────────

public export
withKey : String -> Widget msg -> Widget msg
withKey = Keyed

public export
lazy : Widget msg -> Widget msg
lazy w = Suspend w

public export
portal : Widget msg -> Widget msg
portal = Portal

||| Map a function over the message type (alias for Functor map).
public export
mapMsg : {0 msgA, msgB : Type} -> (msgA -> msgB) -> Widget msgA -> Widget msgB
mapMsg = map
