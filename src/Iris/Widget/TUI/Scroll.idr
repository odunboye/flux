||| Iris.Widget.TUI.Scroll
||| Scrollable output pane — for streaming text, logs, and LLM output.
|||
||| Typical usage for a coding agent:
|||
|||   appendLine "tool: reading file…"  scrollSt  -- add a complete line
|||   appendText  token                 scrollSt  -- stream an LLM token
|||   scrollUp    3                     scrollSt  -- user scrolls back
|||   scrollToEnd                       scrollSt  -- jump to tail + re-enable auto-scroll
module Iris.Widget.TUI.Scroll

import Iris.Backend.Terminal.Types
import Iris.Widget.TUI.Core
import Iris.Widget.TUI.Primitives

-- ─── Local helpers ───────────────────────────────────────────────────────────

scrDrop : Nat -> List x -> List x
scrDrop Z     xs        = xs
scrDrop _     []        = []
scrDrop (S n) (_ :: xs) = scrDrop n xs

scrTake : Nat -> List x -> List x
scrTake Z     _         = []
scrTake _     []        = []
scrTake (S n) (x :: xs) = x :: scrTake n xs

scrRep : Nat -> c -> List c
scrRep Z     _ = []
scrRep (S n) x = x :: scrRep n x

scrDiv : Nat -> Nat -> Nat
scrDiv _ Z     = 0
scrDiv n (S d) = cast {to=Nat} (cast {to=Int} n `div` cast {to=Int} (S d))

-- ─── Hard word-wrap ──────────────────────────────────────────────────────────

||| Split one logical line into visual lines of at most `w` characters.
covering
wrapOne : Nat -> String -> List String
wrapOne Z s = [s]
wrapOne w s =
  let len = length s
  in if len <= w then [s]
     else substr 0 w s :: wrapOne w (substr w (len `minus` w) s)

||| Wrap a list of logical lines to width `w`.
covering
wrapAll : Nat -> List String -> List String
wrapAll _ []        = []
wrapAll w (l :: ls) = wrapOne w l ++ wrapAll w ls

-- ─── ScrollState ─────────────────────────────────────────────────────────────

public export
record ScrollState where
  constructor MkScrollState
  content    : List String   -- logical lines
  scrollTop  : Nat           -- first visible visual line (post-wrap)
  autoScroll : Bool          -- True = always pin to tail

public export
initScroll : ScrollState
initScroll = MkScrollState [] 0 True

||| Append a complete line.
public export
appendLine : String -> ScrollState -> ScrollState
appendLine s st = { content $= (++ [s]) } st

||| Append text to the last logical line (for streaming tokens).
||| If there are no lines yet, starts the first one.
public export
appendText : String -> ScrollState -> ScrollState
appendText t st =
  { content := go st.content } st
  where
    go : List String -> List String
    go []        = [t]
    go (x :: []) = [x ++ t]
    go (x :: xs) = x :: go xs

||| Clear all content and reset scroll position.
public export
clearScroll : ScrollState -> ScrollState
clearScroll _ = initScroll

||| Scroll up by `n` visual lines; disables auto-scroll so the user can read.
public export
scrollUp : Nat -> ScrollState -> ScrollState
scrollUp n st =
  { scrollTop  := if st.scrollTop < n then 0 else st.scrollTop `minus` n
  , autoScroll := False } st

||| Scroll down by `n` visual lines (does not re-enable auto-scroll).
public export
scrollDown : Nat -> ScrollState -> ScrollState
scrollDown n st = { scrollTop $= (+ n) } st

||| Jump to the very top.
public export
scrollToTop : ScrollState -> ScrollState
scrollToTop st = { scrollTop := 0, autoScroll := False } st

||| Jump to the tail and re-enable auto-scroll.
public export
scrollToEnd : ScrollState -> ScrollState
scrollToEnd st = { autoScroll := True } st

-- ─── ScrollConfig ────────────────────────────────────────────────────────────

public export
record ScrollConfig where
  constructor MkScrollConfig
  props         : TUIProps
  contentFg     : TermColor
  contentBg     : TermColor
  showScrollbar : Bool
  scrollbarFg   : TermColor

public export
defaultScrollConfig : TUIProps -> ScrollConfig
defaultScrollConfig p = MkScrollConfig
  { props         = p
  , contentFg     = Default
  , contentBg     = Default
  , showScrollbar = True
  , scrollbarFg   = Color16 8
  }

-- ─── Widget ──────────────────────────────────────────────────────────────────

||| Render a scrollable output pane.
|||
||| `props.width` / `props.height` are outer dimensions (including the border
||| when `props.border` is set).  Content is hard-wrapped to the inner width.
public export
tuiScroll : ScrollConfig -> ScrollState -> TUIWidget msg
tuiScroll cfg st =
  TBox cfg.props (contentWidgets ++ scrollbarWidgets)
  where
    -- ── geometry ─────────────────────────────────────────────────────────────
    bi : Nat
    bi = case cfg.props.border of Nothing => 0; Just _ => 1

    iCol : Nat
    iCol = cfg.props.col + bi

    iRow : Nat
    iRow = cfg.props.row + bi

    iW : Nat
    iW = cfg.props.width `minus` (2 * bi)

    iH : Nat
    iH = cfg.props.height `minus` (2 * bi)

    sbW : Nat
    sbW = if cfg.showScrollbar then 1 else 0

    -- content width (leaves one column for scrollbar when enabled)
    cW : Nat
    cW = iW `minus` sbW

    sbCol : Nat
    sbCol = iCol + cW

    -- ── content slicing ───────────────────────────────────────────────────────
    visual : List String
    visual = wrapAll cW st.content

    lineCount : Nat
    lineCount = length visual

    maxT : Nat
    maxT = if lineCount > iH then lineCount `minus` iH else 0

    top : Nat
    top = if st.autoScroll then maxT
          else if st.scrollTop > maxT then maxT
               else st.scrollTop

    visible : List String
    visible = scrTake iH (scrDrop top visual)

    -- ── helpers ───────────────────────────────────────────────────────────────
    padStr : Nat -> String -> String
    padStr w s =
      let l = length s
      in if l >= w then substr 0 w s
         else s ++ pack (scrRep (w `minus` l) ' ')

    -- ── content rendering ─────────────────────────────────────────────────────
    mkLine : Nat -> String -> TUIWidget msg
    mkLine i s =
      let lp = withFg cfg.contentFg
                 (withBg cfg.contentBg
                   (at iCol (iRow + i)
                     (sized cW 1 cfg.props)))
      in TText lp (padStr cW s)

    goLines : Nat -> List String -> List (TUIWidget msg)
    goLines _ []        = []
    goLines i (s :: ss) = mkLine i s :: goLines (i + 1) ss

    contentWidgets : List (TUIWidget msg)
    contentWidgets = goLines 0 visible

    -- ── scrollbar ─────────────────────────────────────────────────────────────
    -- Returns the scrollbar character for row `i` (0-indexed from inner top).
    sbChar : Nat -> Char
    sbChar i =
      if lineCount <= iH then ' '
      else
        let thumbH   = max 1 (scrDiv (iH * iH) lineCount)
            maxOff   = iH `minus` thumbH
            thumbOff = scrDiv (top * maxOff) (lineCount `minus` iH)
            inThumb  = i >= thumbOff && i < (thumbOff + thumbH)
        in if inThumb then '\x2588' else '\x2591'   -- █ / ░

    mkSbRow : Nat -> TUIWidget msg
    mkSbRow i =
      let sp = withFg cfg.scrollbarFg
                 (at sbCol (iRow + i)
                   (sized 1 1 cfg.props))
      in TText sp (pack [sbChar i])

    goSb : Nat -> Nat -> List (TUIWidget msg)
    goSb _ Z     = []
    goSb i (S n) = mkSbRow i :: goSb (i + 1) n

    scrollbarWidgets : List (TUIWidget msg)
    scrollbarWidgets = if cfg.showScrollbar then goSb 0 iH else []
