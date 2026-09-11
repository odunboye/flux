||| Iris.Widget.TUI.Input
||| Text input field widget.
module Iris.Widget.TUI.Input

import Iris.Backend.Terminal.Types
import Iris.Widget.TUI.Core
import Iris.Widget.TUI.Primitives

-- ─── Local helpers ───────────────────────────────────────────────────────────

inSplitAt : Nat -> List c -> (List c, List c)
inSplitAt Z     xs        = ([], xs)
inSplitAt _     []        = ([], [])
inSplitAt (S n) (x :: xs) =
  let (l, r) = inSplitAt n xs in (x :: l, r)

inDrop : Nat -> List c -> List c
inDrop Z     xs        = xs
inDrop _     []        = []
inDrop (S n) (_ :: xs) = inDrop n xs

inTake : Nat -> List c -> List c
inTake Z     _         = []
inTake _     []        = []
inTake (S n) (x :: xs) = x :: inTake n xs

inInit : List c -> List c
inInit []        = []
inInit (_ :: []) = []
inInit (x :: xs) = x :: inInit xs

inRep : Nat -> c -> List c
inRep Z     _ = []
inRep (S n) x = x :: inRep n x

-- ─── InputState ──────────────────────────────────────────────────────────────

public export
record InputState where
  constructor MkInputState
  value        : String
  cursor       : Nat
  focused      : Bool
  scrollOffset : Nat

public export
initInput : InputState
initInput = MkInputState "" 0 False 0

public export
initInputWith : String -> InputState
initInputWith s = MkInputState s (length s) False 0

public export
insertChar : Char -> InputState -> InputState
insertChar c st =
  let (before, after) = inSplitAt st.cursor (unpack st.value)
  in { value  := pack (before ++ [c] ++ after)
     , cursor $= (+ 1) } st

public export
deleteBack : InputState -> InputState
deleteBack st =
  if st.cursor == 0 then st
  else
    let (before, after) = inSplitAt st.cursor (unpack st.value)
    in { value  := pack (inInit before ++ after)
       , cursor $= (`minus` 1) } st

public export
deleteForward : InputState -> InputState
deleteForward st =
  let (before, after) = inSplitAt st.cursor (unpack st.value)
  in case after of
       []          => st
       (_ :: rest) => { value := pack (before ++ rest) } st

public export
cursorLeft : InputState -> InputState
cursorLeft st = { cursor $= (`minus` 1) } st

public export
cursorRight : InputState -> InputState
cursorRight st = { cursor := min (length st.value) (st.cursor + 1) } st

public export
cursorToHome : InputState -> InputState
cursorToHome st = { cursor := 0 } st

public export
cursorToEnd : InputState -> InputState
cursorToEnd st = { cursor := length st.value } st

public export
clearInput : InputState -> InputState
clearInput _ = initInput

-- ─── InputConfig ─────────────────────────────────────────────────────────────

public export
record InputConfig where
  constructor MkInputConfig
  props         : TUIProps
  placeholder   : String
  password      : Bool
  focusedFg     : TermColor
  focusedBg     : TermColor
  blurredFg     : TermColor
  blurredBg     : TermColor
  placeholderFg : TermColor

public export
defaultInputConfig : TUIProps -> InputConfig
defaultInputConfig p = MkInputConfig
  { props         = p
  , placeholder   = ""
  , password      = False
  , focusedFg     = Color16 15
  , focusedBg     = Color16 4
  , blurredFg     = Color16 7
  , blurredBg     = Default
  , placeholderFg = Color16 8
  }

-- ─── Display helpers ─────────────────────────────────────────────────────────

displayWindow : String -> Nat -> Nat -> String
displayWindow s cur w =
  let chars  = unpack s
      offset = if cur >= w then cur `minus` (w `minus` 1) else 0
  in pack (inTake w (inDrop offset chars))

inputDisplayString : InputConfig -> InputState -> String
inputDisplayString cfg st =
  let content = if cfg.password
                  then pack (inRep (length st.value) '\x25cf')
                  else st.value
  in displayWindow content st.cursor cfg.props.width

-- ─── Widget ──────────────────────────────────────────────────────────────────

||| Render a text input field.
public export
tuiInput : InputConfig -> InputState -> TUIWidget msg
tuiInput cfg st =
  let display = if length st.value == 0 && not st.focused
                  then cfg.placeholder
                  else inputDisplayString cfg st
      fg = if st.focused then cfg.focusedFg else cfg.blurredFg
      bg = if st.focused then cfg.focusedBg else cfg.blurredBg
      innerProps = withFg fg (withBg bg
                    (at (cfg.props.col + 1) (cfg.props.row + 1)
                      (sized (cfg.props.width `minus` 2) 1 cfg.props)))
  in TBox cfg.props [TText innerProps display]
