||| Iris.Widget.TUI.Core
||| The concrete TUI widget type.
|||
||| Unlike the abstract Widget msg (which carries no render data),
||| TUIWidget carries every piece of information needed to produce ANSI
||| output directly. Widget constructors in the other TUI modules reduce
||| to one of the four concrete cases below.
|||
||| The renderer is a pure function: TUIWidget msg -> String.
||| No IORef, no mutable state — just ANSI escape sequences.
module Iris.Widget.TUI.Core

import Iris.Backend.Terminal.Types

-- ─── TUIWidget ───────────────────────────────────────────────────────────────

public export
data TUIWidget : (msg : Type) -> Type where

  ||| A single line (or run of text) drawn at props.col / props.row.
  ||| Long strings are clipped at props.width if width > 0.
  TText  : TUIProps -> String -> TUIWidget msg

  ||| A rectangular panel.  If props.border is set the border is drawn;
  ||| props.title is embedded in the top border line.
  ||| Children are rendered after the border (they use their own absolute
  ||| positions so no layout pass is needed in Phase 0).
  TBox   : TUIProps -> List (TUIWidget msg) -> TUIWidget msg

  ||| Lay children out left-to-right, each at its own absolute position.
  THBox  : TUIProps -> List (TUIWidget msg) -> TUIWidget msg

  ||| Lay children out top-to-bottom, each at its own absolute position.
  TVBox  : TUIProps -> List (TUIWidget msg) -> TUIWidget msg

  ||| Lift a message transform into the widget tree (Functor).
  TMap   : {0 a, b : Type} -> (a -> b) -> TUIWidget a -> TUIWidget b

-- ─── Functor ─────────────────────────────────────────────────────────────────

public export
Functor TUIWidget where
  map _ (TText  p s)    = TText  p s
  map f (TBox   p cs)   = TBox   p (map (map f) cs)
  map f (THBox  p cs)   = THBox  p (map (map f) cs)
  map f (TVBox  p cs)   = TVBox  p (map (map f) cs)
  map f (TMap g w)      = TMap   (f . g) w

-- ─── Smart aliases ───────────────────────────────────────────────────────────

public export
tuiEmpty : TUIWidget msg
tuiEmpty = TText defaultTUI ""
