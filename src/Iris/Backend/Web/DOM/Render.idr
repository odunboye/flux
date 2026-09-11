||| Iris.Backend.Web.DOM.Render
||| Renders an abstract Widget tree to an HTML string.
|||
||| The generated HTML uses:
|||   - CSS custom properties for the colour palette
|||   - flex-box for VStack / HStack layout
|||   - Semantic elements where possible (button, input, progress)
|||
||| Event wiring
||| ────────────
||| Interactive widgets (buttons, checkboxes, inputs) are assigned a
||| sequential integer ID during rendering.  DOM event handlers push
||| that ID into `window.__irisEvents`.  The Idris2 main loop polls
||| the queue, resolves the ID back to a message, and dispatches it.
module Iris.Backend.Web.DOM.Render

import Data.IORef
import Iris.Widget

-- ─── Colour mapping ──────────────────────────────────────────────────────────

colorToCSS : IrisColor -> String
colorToCSS Inherit       = "inherit"
colorToCSS (IRGB r g b)  = "rgb(" ++ show r ++ "," ++ show g ++ "," ++ show b ++ ")"
colorToCSS IBlue         = "#58a6ff"
colorToCSS IRed          = "#ff7b72"
colorToCSS IGreen        = "#3fb950"
colorToCSS IYellow       = "#d29922"
colorToCSS ICyan         = "#39c5cf"
colorToCSS IMagenta      = "#bc8cff"
colorToCSS IWhite        = "#f0f6fc"
colorToCSS IBlack        = "#0d1117"
colorToCSS IGray         = "#8b949e"
colorToCSS ILightBlue    = "#79c0ff"
colorToCSS ILightGreen   = "#56d364"
colorToCSS ILightRed     = "#ffa198"
colorToCSS ILightYellow  = "#e3b341"
colorToCSS IDarkBlue     = "#1f6feb"
colorToCSS IDarkGray     = "#6e7681"

-- ─── Style → inline CSS ──────────────────────────────────────────────────────

styleToCSS : Style -> String
styleToCSS s =
  let fg   = case s.fg of Nothing => ""; Just c => "color:" ++ colorToCSS c ++ ";"
      bg   = case s.bg of Nothing => ""; Just c => "background:" ++ colorToCSS c ++ ";"
      bld  = if s.bold      then "font-weight:700;" else ""
      itl  = if s.italic    then "font-style:italic;" else ""
      ul   = if s.underline then "text-decoration:underline;" else ""
      padS = if s.padH > 0 || s.padV > 0
             then "padding:" ++ show s.padV ++ "px " ++ show s.padH ++ "px;"
             else ""
      -- border
      brdS = case s.border of
               NoBorder      => ""
               ThinBorder    => "border:1px solid #30363d;border-radius:4px;"
               ThickBorder   => "border:2px solid #58a6ff;border-radius:4px;"
               RoundedBorder => "border:1px solid #30363d;border-radius:8px;"
  in fg ++ bg ++ bld ++ itl ++ ul ++ padS ++ brdS

-- Flex fill helper
flexStyle : Style -> String
flexStyle s =
  (if s.fillH then "flex:1;" else "") ++
  (if s.fillV then "align-self:stretch;" else "")

-- ─── Spinner frames ──────────────────────────────────────────────────────────

spinFrame : Nat -> String
spinFrame n =
  let frames = ["⠋","⠙","⠹","⠸","⠼","⠴","⠦","⠧","⠇","⠏"]
      idx    = cast {to=Nat} (cast {to=Int} n `mod` 10)
  in case getAt idx frames of
       Nothing => "⠋"
       Just s  => s
  where
    getAt : Nat -> List a -> Maybe a
    getAt _     []       = Nothing
    getAt Z     (x :: _) = Just x
    getAt (S k) (_ :: xs)= getAt k xs

-- ─── Progress bar ────────────────────────────────────────────────────────────

renderProgress : Double -> String
renderProgress frac =
  let pct = show (cast {to=Int} (frac * 100.0))
  in "<div class='iris-progress' role='progressbar' aria-label='Progress' aria-valuemin='0' aria-valuemax='100' aria-valuenow='" ++ pct ++ "'>" ++
     "<div class='iris-progress-bar' style='width:" ++ pct ++ "%'></div>" ++
     "<span class='iris-progress-label' aria-hidden='true'>" ++ pct ++ "%</span>" ++
     "</div>"

-- ─── Sparkline ───────────────────────────────────────────────────────────────

sparkChars : List Char
sparkChars = ['▁','▂','▃','▄','▅','▆','▇','█']

sparkChar : Double -> String
sparkChar v =
  let idx = cast {to=Nat} (cast {to=Int} (v * 7.0))
      idx' = if idx > 7 then 7 else idx
  in case getAt idx' sparkChars of
       Nothing => "▁"
       Just c  => pack [c]
  where
    getAt : Nat -> List a -> Maybe a
    getAt _     []       = Nothing
    getAt Z     (x :: _) = Just x
    getAt (S k) (_ :: xs)= getAt k xs

-- ─── HTML escaping ───────────────────────────────────────────────────────────

escapeHTML : String -> String
escapeHTML s = concatMap escChar (unpack s)
  where
    escChar : Char -> String
    escChar '&'  = "&amp;"
    escChar '<'  = "&lt;"
    escChar '>'  = "&gt;"
    escChar '"'  = "&quot;"
    escChar '\'' = "&#39;"
    escChar c    = pack [c]

-- ─── Event ID state ──────────────────────────────────────────────────────────

-- We thread a mutable counter through rendering so each interactive
-- widget gets a unique stable integer key.

RenderState : Type
RenderState = IORef Nat

newRenderState : IO RenderState
newRenderState = newIORef 0

nextId : RenderState -> IO Nat
nextId st = do
  n <- readIORef st
  writeIORef st (n + 1)
  pure n

-- ─── Render ──────────────────────────────────────────────────────────────────

||| Render a widget to an HTML string.
||| `idMap` is extended with new (id → msg) pairs for interactive
||| widgets whose event carries no payload (buttons, checkboxes).
||| `inputMap` is the same idea for `WInput` specifically, whose event
||| DOES carry a payload (the field's current text) - `onChange : String
||| -> msg` can't be pre-applied to a concrete `msg` at render time the
||| way a button's fixed `msg` can, so it's registered as a function and
||| applied once the runtime actually reads the live DOM value (see
||| `Iris.Backend.Web.DOM.Run.drainInputs`).
public export
webListTake : Nat -> List a -> List a
webListTake Z     _        = []
webListTake _     []       = []
webListTake (S n) (x :: xs)= x :: webListTake n xs

mapIO : (a -> IO b) -> List a -> IO (List b)
mapIO _ []        = pure []
mapIO f (x :: xs) = do r <- f x; rs <- mapIO f xs; pure (r :: rs)

public export
renderHTML : Widget msg -> RenderState -> IORef (List (Nat, msg))
           -> IORef (List (Nat, String -> msg)) -> IO String
renderHTML (WText s str) _ _ _ = do
  let css = styleToCSS s ++ flexStyle s
  case s.label of
    Nothing => pure $ "<span style='" ++ css ++ "'>" ++ escapeHTML str ++ "</span>"
    Just t  => pure $
      "<div style='position:relative;padding-top:20px;" ++ css ++ "'>" ++
      "<span class='iris-box-title'>" ++ escapeHTML t ++ "</span>" ++
      escapeHTML str ++ "</div>"

renderHTML (WVStack s children) st idMap inputMap = do
  let brd   = case s.border of
                NoBorder => ""
                _        => "border:1px solid #30363d;border-radius:6px;padding:12px;"
      css   = "display:flex;flex-direction:column;gap:4px;" ++
              brd ++ styleToCSS s ++ flexStyle s
  inner <- mapIO (\c => renderHTML c st idMap inputMap) children
  let title = case s.label of
                Nothing => ""
                Just t  => "<div class='iris-panel-title'>" ++ escapeHTML t ++ "</div>"
  let semantics = case s.label of
                    Nothing => " role='group'"
                    Just label => " role='group' aria-label='" ++ escapeHTML label ++ "'"
  pure $ "<div" ++ semantics ++ " style='" ++ css ++ "'>" ++ title ++ concat inner ++ "</div>"

renderHTML (WHStack s children) st idMap inputMap = do
  let css = "display:flex;flex-direction:row;gap:8px;" ++
            styleToCSS s ++ flexStyle s
  inner <- mapIO (\c => renderHTML c st idMap inputMap) children
  let semantics = case s.label of
                    Nothing => " role='group'"
                    Just label => " role='group' aria-label='" ++ escapeHTML label ++ "'"
  pure $ "<div" ++ semantics ++ " style='" ++ css ++ "'>" ++ concat inner ++ "</div>"

renderHTML (WButton s label msg) st idMap _ = do
  eid <- nextId st
  modifyIORef idMap ((eid, msg) ::)
  let css = "cursor:pointer;padding:6px 14px;border-radius:6px;" ++
            "border:1px solid #30363d;background:#21262d;" ++
            "color:#c9d1d9;font-size:14px;" ++ styleToCSS s
  pure $ "<button type='button' aria-label='" ++ escapeHTML label ++ "' style='" ++ css ++ "' " ++
         "onclick='__irisClick(" ++ show eid ++ ")'>" ++
         escapeHTML label ++ "</button>"

renderHTML (WCheckbox s checked msg) st idMap _ = do
  eid <- nextId st
  modifyIORef idMap ((eid, msg) ::)
  let chk = if checked then " checked" else ""
      css = "display:flex;align-items:center;gap:8px;cursor:pointer;" ++
            styleToCSS s
  let accessibleName = case s.label of Nothing => "Toggle"; Just label => label
  pure $ "<label style='" ++ css ++ "'>" ++
         "<input type='checkbox' aria-label='" ++ escapeHTML accessibleName ++ "'" ++ chk ++
         " onchange='__irisClick(" ++ show eid ++ ")'/>" ++
         "</label>"

renderHTML (WInput s val onChange) st _ inputMap = do
  eid <- nextId st
  modifyIORef inputMap ((eid, onChange) ::)
  let css = "background:#0d1117;border:1px solid #30363d;border-radius:4px;" ++
            "padding:8px 12px;color:#c9d1d9;font-family:inherit;width:100%;" ++
            "font-size:14px;caret-color:#58a6ff;" ++ styleToCSS s
  -- `id='iris-input-<eid>'` is load-bearing, not cosmetic: `setHTML`
  -- (see `Run.idr`) replaces `#iris-app`'s entire `innerHTML` on every
  -- render tick, which destroys and recreates every descendant node -
  -- including whichever `<input>` currently has real browser focus.
  -- `setHTML` saves the focused element's id + selection beforehand and
  -- restores focus to the (newly-recreated) element with the same id
  -- afterward - that only works if the id is stable across renders,
  -- which it is here as long as this widget's position in the tree
  -- (and hence its turn in the shared `RenderState` counter) doesn't
  -- change between one render and the next.
  -- `autocomplete='off'` - confirmed directly, not precautionary: a
  -- real (non-readonly) `<input>` with no `name`/type-specific hint is
  -- still a candidate for Chrome's own autofill-prediction dropdown
  -- (built from OTHER sites' form history, not anything this app ever
  -- wrote), and accepting a suggestion from it goes through the exact
  -- same `oninput` this field already wires - indistinguishable from
  -- real typing to `onChange`. Seen firsthand mid-testing: an unrelated
  -- autofill suggestion got submitted as a real todo.
  let accessibleName = case s.label of Nothing => "Text input"; Just label => label
  pure $ "<input type='text' aria-label='" ++ escapeHTML accessibleName ++ "' id='iris-input-" ++ show eid ++ "' autocomplete='off' style='" ++ css ++ "' " ++
         "value='" ++ escapeHTML val ++ "' " ++
         "oninput='__irisInput(" ++ show eid ++ ", this.value)'/>"

renderHTML (WProgress s frac) _ _ _ =
  pure (renderProgress frac)

renderHTML (WSpinner s tick) _ _ _ = do
  let css   = styleToCSS s
      frame = spinFrame tick
  pure $ "<span class='iris-spinner' role='status' aria-live='polite' aria-label='Working' style='" ++ css ++ "'>" ++
         "<span aria-hidden='true'>" ++ frame ++ "</span></span>"

renderHTML (WSparkline s vals) _ _ _ = do
  let css   = styleToCSS s
      chars = concat (map sparkChar (webListTake 20 vals))
  pure $ "<span class='iris-sparkline' style='" ++ css ++ "'>" ++ chars ++ "</span>"

renderHTML WSpacer _ _ _ =
  pure "<div style='flex:1'></div>"

renderHTML (WDivider s) _ _ _ = do
  let css = "border:none;border-top:1px solid #30363d;margin:4px 0;" ++
            styleToCSS s
  pure $ "<hr style='" ++ css ++ "'/>"

-- ─── CSS stylesheet ──────────────────────────────────────────────────────────

||| Minimal CSS injected once into the page head.
public export
irisCSS : String
irisCSS = """
  :root {
    --iris-bg:     #0d1117;
    --iris-fg:     #c9d1d9;
    --iris-border: #30363d;
    --iris-accent: #58a6ff;
    --iris-muted:  #8b949e;
    --iris-sel-bg: #1f6feb33;
  }
  body {
    background: var(--iris-bg);
    color: var(--iris-fg);
    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
    font-size: 14px;
    line-height: 1.5;
    margin: 0;
    padding: 0;
    overflow-x: hidden;
  }
  #iris-app {
    box-sizing: border-box;
    width: 100%;
    padding: clamp(12px, 4vw, 24px);
    max-width: 900px;
    margin: 0 auto;
  }
  .iris-progress {
    position: relative;
    height: 8px;
    background: #21262d;
    border-radius: 4px;
    overflow: hidden;
    margin: 6px 0;
  }
  .iris-progress-bar {
    height: 100%;
    background: linear-gradient(90deg, #1f6feb, #58a6ff);
    transition: width 0.3s ease;
  }
  .iris-progress-label {
    position: absolute;
    right: 0;
    top: -18px;
    font-size: 11px;
    color: var(--iris-muted);
  }
  .iris-panel-title {
    font-size: 11px;
    font-weight: 600;
    color: var(--iris-muted);
    text-transform: uppercase;
    letter-spacing: 0.08em;
    margin-bottom: 6px;
  }
  .iris-box-title {
    position: absolute;
    top: 0;
    left: 12px;
    background: var(--iris-bg);
    padding: 0 6px;
    font-size: 11px;
    color: var(--iris-muted);
  }
  .iris-sparkline {
    font-family: monospace;
    letter-spacing: 1px;
    color: #3fb950;
  }
  .iris-spinner { font-family: monospace; }
  input[type='checkbox'] { accent-color: var(--iris-accent); width: 16px; height: 16px; }
  button:hover { background: #30363d !important; }
  button:focus-visible, input:focus-visible {
    outline: 3px solid var(--iris-accent);
    outline-offset: 2px;
  }
  @media (prefers-reduced-motion: reduce) {
    *, *::before, *::after {
      animation-duration: 0.01ms !important;
      animation-iteration-count: 1 !important;
      transition-duration: 0.01ms !important;
      scroll-behavior: auto !important;
    }
  }
  @media (max-width: 600px) {
    body { font-size: 16px; }
    button { min-width: 44px; min-height: 44px; }
    input[type='text'] { min-height: 44px; box-sizing: border-box; }
    input[type='checkbox'] { width: 24px; height: 24px; }
  }
"""

-- ─── Top-level render ────────────────────────────────────────────────────────

||| Render the widget tree to an HTML fragment, a fresh ID→msg map (for
||| buttons/checkboxes), and a fresh ID→(String -> msg) map (for
||| `WInput`'s `onChange`).
public export
renderPage : Widget msg -> IO (String, List (Nat, msg), List (Nat, String -> msg))
renderPage w = do
  st       <- newRenderState
  idMap    <- newIORef (the (List (Nat, msg)) [])
  inputMap <- newIORef (the (List (Nat, String -> msg)) [])
  html     <- renderHTML w st idMap inputMap
  pairs    <- readIORef idMap
  inputs   <- readIORef inputMap
  pure (html, pairs, inputs)
