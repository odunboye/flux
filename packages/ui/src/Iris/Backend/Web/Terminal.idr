||| Iris.Backend.Web.Terminal
||| xterm.js-backed web terminal renderer.
|||
||| This module provides `runWebTerm`, a drop-in replacement for
||| `Iris.Backend.Terminal.App.runTUI` for browser targets.
|||
||| The same `TUIApp` record and `renderFrame` pipeline are reused
||| unchanged — the only difference is the output target (xterm.js
||| instead of stdout) and the input source (DOM keyboard events
||| routed through a global JS queue instead of raw stdin).
|||
||| Prerequisites in your index.html (before the compiled JS):
|||   <link rel="stylesheet"
|||         href="https://cdn.jsdelivr.net/npm/xterm@5/css/xterm.css"/>
|||   <script src="https://cdn.jsdelivr.net/npm/xterm@5/lib/xterm.min.js">
|||   </script>
|||   <div id="terminal"></div>
module Iris.Backend.Web.Terminal

import Data.IORef
import Iris.State.TEA
import Iris.Platform.Event
import Iris.Backend.Terminal.Types
import Iris.Backend.Terminal.ANSI
import Iris.Backend.Terminal.Renderer
import Iris.Backend.Terminal.App
import Iris.Widget.TUI.Core

-- ─── xterm.js FFI ────────────────────────────────────────────────────────────
--
-- Design rationale for the key queue:
--   Passing an `IO ()` closure to `setInterval` / `onKey` requires the
--   exact Idris2-JS world-passing calling convention, which varies between
--   compiler versions.  Instead we use a plain JS side-channel:
--     * The `onKey` callback pushes raw key strings into window.__irisKeys[].
--     * Idris2 calls prim_pollKey to shift() one string per frame.
--   No IO value ever crosses the FFI boundary as a callback.

||| Create a new xterm.js Terminal (80 × 24, dark GitHub theme).
%foreign "javascript:lambda: _w => new Terminal({ cols: 80, rows: 24, convertEol: true, cursorBlink: false, fontSize: 14, fontFamily: 'Menlo, Monaco, Consolas, monospace', theme: { background: '#0d1117', foreground: '#c9d1d9', cursor: '#58a6ff', selectionBackground: '#264f78', black: '#484f58', red: '#ff7b72', green: '#3fb950', yellow: '#d29922', blue: '#58a6ff', magenta: '#bc8cff', cyan: '#39c5cf', white: '#b1bac4', brightBlack: '#6e7681', brightRed: '#ffa198', brightGreen: '#56d364', brightYellow: '#e3b341', brightBlue: '#79c0ff', brightMagenta: '#d2a8ff', brightCyan: '#56d4dd', brightWhite: '#f0f6fc' } })"
prim_newTerm : PrimIO AnyPtr

||| Mount the terminal into a DOM element (CSS selector).
%foreign "javascript:lambda: (term, sel, _w) => { term.open(document.querySelector(sel)); term.focus(); }"
prim_openTerm : AnyPtr -> String -> PrimIO ()

||| Write an ANSI string to the xterm.js terminal.
%foreign "javascript:lambda: (s, term, _w) => term.write(s)"
prim_writeTerm : String -> AnyPtr -> PrimIO ()

||| Initialise the global key queue and attach the onKey listener.
||| Keys are stored as browser KeyboardEvent.key strings, e.g.
|||   "a", " ", "Enter", "Backspace", "Escape",
|||   "ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight"
||| These match our handleKey patterns directly — no re-mapping needed.
%foreign "javascript:lambda: (term, _w) => { window.__irisKeys = window.__irisKeys || []; term.onKey(function(e){ window.__irisKeys.push(e.key); }); }"
prim_setupQueue : AnyPtr -> PrimIO ()

||| Shift one key string from the global queue.  Returns '' if empty.
%foreign "javascript:lambda: _w => (window.__irisKeys && window.__irisKeys.length > 0) ? window.__irisKeys.shift() : ''"
prim_pollKey : PrimIO String

||| Schedule a one-shot JS timeout (milliseconds).
||| `f` is compiled to a JS function; calling `f(0)` runs the IO action.
%foreign "javascript:lambda: (ms, f, _w) => setTimeout(function(){ f(0); }, ms)"
prim_setTimeout : Int -> IO () -> PrimIO ()

-- ─── Idris2 wrappers ─────────────────────────────────────────────────────────

newTerm : IO AnyPtr
newTerm = primIO prim_newTerm

openTerm : AnyPtr -> String -> IO ()
openTerm term sel = primIO (prim_openTerm term sel)

writeTerm : AnyPtr -> String -> IO ()
writeTerm term s = primIO (prim_writeTerm s term)

setupQueue : AnyPtr -> IO ()
setupQueue term = primIO (prim_setupQueue term)

pollKey : IO String
pollKey = primIO prim_pollKey

scheduleIn : Int -> IO () -> IO ()
scheduleIn ms action = primIO (prim_setTimeout ms action)

-- ─── Web key → KeyEvent ──────────────────────────────────────────────────────
--
-- xterm.js reports keys via the browser's KeyboardEvent.key standard, which
-- already uses the same string names our handleKey matches against:
--   printable chars  →  "a", "A", "1", " ", …
--   special keys     →  "Enter", "Backspace", "Escape", "Tab", …
--   arrows           →  "ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight"
--   function keys    →  "F1" … "F12"
-- No translation layer is needed beyond wrapping the string in a KeyEvent.

webKey : String -> KeyEvent
webKey k =
  let noMods = MkModifiers False False False False
      ch     = case unpack k of [c] => Just c; _ => Nothing
  in MkKeyEvent KeyDown k k noMods ch

-- ─── Cmd executor (web version) ──────────────────────────────────────────────

isQuitCmd : Cmd msg -> Bool
isQuitCmd QuitApp    = True
isQuitCmd (Batch cs) = any isQuitCmd cs
isQuitCmd _          = False

webExecCmd : Cmd outMsg -> (outMsg -> IO ()) -> IORef Bool -> IO ()
webExecCmd None             _    _       = pure ()
webExecCmd (Batch cs)       send quitRef = traverse_ (\c => webExecCmd c send quitRef) cs
webExecCmd (MapCmd f c)     send quitRef = webExecCmd c (send . f) quitRef
webExecCmd (Task io)        send _       = io >>= send
webExecCmd (StreamTask act) send _       = act send
webExecCmd (CancellableTask act) send _  = ignore (act send)
webExecCmd QuitApp          _    quitRef = writeIORef quitRef True

-- ─── Message dispatcher ──────────────────────────────────────────────────────

webDispatch : TUIApp mdl outMsg -> IORef mdl -> IORef Bool -> outMsg -> IO ()
webDispatch app modelRef quitRef msg = do
  m <- readIORef modelRef
  let (m', cmd) = app.update msg m
  writeIORef modelRef m'
  webExecCmd cmd (webDispatch app modelRef quitRef) quitRef

-- ─── Key drain ───────────────────────────────────────────────────────────────

-- Drain all queued key events and dispatch them.
drainKeys : TUIApp mdl outMsg -> IORef mdl -> IORef Bool -> IO ()
drainKeys app modelRef quitRef = do
  k <- pollKey
  case k of
    "" => pure ()
    _  => do
      quit <- readIORef quitRef
      when (not quit) $ do
        m <- readIORef modelRef
        case app.handleKey m (webKey k) of
          Nothing  => pure ()
          Just msg => webDispatch app modelRef quitRef msg
        drainKeys app modelRef quitRef

-- ─── Render / event loop ─────────────────────────────────────────────────────

webLoop : TUIApp mdl outMsg -> AnyPtr -> IORef mdl -> IORef Bool -> IO ()
webLoop app term modelRef quitRef = do
  quit <- readIORef quitRef
  if quit
    then do
      -- Show farewell message and stop scheduling frames
      writeTerm term (clearScreen ++ cursorHome
        ++ "\x1b[1;32m  Bye! Refresh the page to restart.\x1b[0m\r\n")
    else do
      -- 1. Process all pending keys
      drainKeys app modelRef quitRef

      -- 2. Render (if still alive)
      quit2 <- readIORef quitRef
      when (not quit2) $ do
        mdl <- readIORef modelRef
        writeTerm term (renderFrame (app.view mdl))

        -- 3. Schedule next frame (~30 fps)
        scheduleIn 33 (webLoop app term modelRef quitRef)

-- ─── Tick dispatcher ─────────────────────────────────────────────────────────

-- Dispatch tickMsg on the given interval (milliseconds).
tickLoop : TUIApp mdl outMsg -> IORef mdl -> IORef Bool -> Int -> IO ()
tickLoop app modelRef quitRef ms = do
  quit <- readIORef quitRef
  when (not quit) $ do
    case app.tickMsg of
      Nothing => pure ()
      Just tm => webDispatch app modelRef quitRef tm
    scheduleIn ms (tickLoop app modelRef quitRef ms)

-- ─── Public entry point ──────────────────────────────────────────────────────

||| Run a TUIApp in the browser, using xterm.js for rendering.
|||
||| Call this from your `main : IO ()` instead of `runTUI`.
||| The function returns immediately; all further work is done in
||| JS setTimeout callbacks (non-blocking, browser event-loop driven).
public export
runWebTerm : TUIApp mdl outMsg -> IO ()
runWebTerm app = do
  -- Create and mount the xterm.js terminal widget
  term <- newTerm
  openTerm term "#terminal"
  setupQueue term

  -- Initialise the TEA model
  let (initMdl, initCmd) = app.init
  modelRef <- newIORef initMdl
  quitRef  <- newIORef False

  -- Execute startup commands
  webExecCmd initCmd (webDispatch app modelRef quitRef) quitRef

  -- Enter full-screen TUI mode (clears the xterm canvas)
  writeTerm term (termInit ++ cursorHome)

  -- Initial render
  mdl <- readIORef modelRef
  writeTerm term (renderFrame (app.view mdl))

  -- Start animation tick (every 100 ms)
  scheduleIn 100 (tickLoop app modelRef quitRef 100)

  -- Start render/event loop (every 33 ms ≈ 30 fps)
  scheduleIn 33 (webLoop app term modelRef quitRef)
