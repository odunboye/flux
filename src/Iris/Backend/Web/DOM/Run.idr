||| Iris.Backend.Web.DOM.Run
||| Browser entry point: runs an abstract Iris App using DOM rendering.
|||
||| Use this from your browser Main.idr:
|||
|||   main : IO ()
|||   main = runWeb myApp
|||
||| The same `myApp` value can be passed to
|||   Iris.Backend.Terminal.Run.runTUI   (terminal)
||| without changing any application code.
|||
||| Runtime architecture
||| ────────────────────
||| • ONE ordered event queue, `window.__irisEvents` - every input
|||   source (keydown, button/checkbox click, `WInput` text change)
|||   pushes a tagged entry onto it, and `drainAll` (below) processes
|||   them strictly in arrival order every frame. This matters, and
|||   used to be three SEPARATE queues (keys, clicks, inputs), each
|||   fully drained in a fixed key-then-click-then-input order every
|||   tick regardless of what order the events actually happened in - a
|||   real bug, not a hypothetical: edit a field then click "Save"
|||   within the same ~33ms frame, and the old code ran EVERY click
|||   before ANY input-change, so `Save` dispatched against the model's
|||   STALE field value, one frame behind what the user just typed. A
|||   single tagged queue preserves true chronological order across all
|||   three sources instead.
|||     - `K<key>` - a keydown, resolved via `IrisApp.handleKey`.
|||     - `C<id>` - a button/checkbox activation, `id` resolved to a
|||       `msg` through the per-render `idMap`.
|||     - `I<id><sep><value>` - a `WInput` change (`sep` = `chr 1`),
|||       `id` resolved to an `onChange : String -> msg` through the
|||       per-render `inputMap`, applied to `value`.
||| • A `setTimeout(33ms)` chain drives the render loop (~30 fps).
||| • A `setTimeout(100ms)` chain drives the animation tick.
|||
||| Every render tick replaces `#iris-app`'s entire `innerHTML` - there
||| is no virtual-DOM diff/patch here, the whole tree is re-stringified
||| and swapped in wholesale every ~33ms regardless of whether anything
||| actually changed. That's fine for everything EXCEPT real browser
||| focus: an `innerHTML` replace destroys and recreates every
||| descendant node, including whichever `<input>` currently has focus
||| (and the user's cursor position/selection in it) - confirmed
||| directly, not assumed: before `setHTML` below saved/restored it,
||| typing a single character into a `WInput` field lost focus on that
||| same tick, making a second keystroke impossible without re-clicking
||| the field. `setHTML`'s JS body saves `document.activeElement`'s id
||| and selection range beforehand (only if it's one of ours - an
||| `INPUT` inside `#iris-app` with an id) and restores both onto the
||| newly-recreated element with the same id afterward. This works
||| because `Iris.Backend.Web.DOM.Render`'s `WInput` case gives its
||| `<input>` a stable id (`iris-input-<n>`, `n` from the shared
||| per-render counter) - stable ACROSS renders only as long as the
||| widget's position in the tree doesn't change relative to other
||| interactive widgets, same caveat every id in this module already has
||| (`idMap`/`inputMap` are both rebuilt fresh every render, not
||| diffed).
module Iris.Backend.Web.DOM.Run

import Data.IORef
import Iris.State.TEA
import Iris.Platform.Event
import Iris.App
import Iris.Widget
import Iris.Backend.Web.DOM.Render
import Iris.Runtime.Common
import Iris.App.EventWire

-- ─── JS FFI ──────────────────────────────────────────────────────────────────

-- Inject a <style> tag into <head>
%foreign "javascript:lambda: (css, _w) => { const s=document.createElement('style'); s.textContent=css; document.head.appendChild(s); }"
prim_injectCSS : String -> PrimIO ()

-- Set the innerHTML of #iris-app, preserving real browser focus and
-- text selection across the replace - see this module's doc comment
-- for why that's necessary, not optional, once any `WInput` is a real
-- (non-readonly) field.
%foreign "javascript:lambda: (html, _w) => { const el=document.getElementById('iris-app'); if(!el) return; let focusedId=null, selStart=0, selEnd=0; const active=document.activeElement; if(active && el.contains(active) && active.tagName==='INPUT' && active.id){ focusedId=active.id; try{ selStart=active.selectionStart||0; selEnd=active.selectionEnd||0; }catch(e){} } el.innerHTML=html; if(focusedId){ const ne=document.getElementById(focusedId); if(ne){ ne.focus(); try{ ne.setSelectionRange(selStart, selEnd); }catch(e){} } } }"
prim_setHTML : String -> PrimIO ()

-- Set up ONE ordered event queue, then attach the keyboard listener.
-- Every source pushes a TAGGED entry - "K<key>" (keydown), "C<id>"
-- (button/checkbox click), "I<id><sep><value>" (WInput change, sep =
-- chr 1) - so `drainAll` (below) can process all three in the order
-- they actually happened, not per-type batches (see this module's own
-- doc comment for why that distinction is load-bearing, not cosmetic).
--
-- The `preventDefault()` on Arrow*/Space is only correct when nothing
-- with real native text-editing behavior has focus - it exists so
-- Space/arrow-key APP NAVIGATION (list selection, toggling) doesn't
-- also scroll the page, the same conflict a plain `<button>` already
-- guards against by default. A confirmed real regression from making
-- `WInput` a genuine (non-readonly) field: applied unconditionally,
-- this same `preventDefault()` also blocked the BROWSER's own default
-- behavior for a focused text input - Space could not be typed into it
-- at all, since the keydown was suppressed before the browser ever got
-- to insert the character. Gated on `document.activeElement` now: an
-- `<input>` in focus gets its normal native text-editing behavior;
-- nothing focused (the traditional TUI-nav-on-a-page case) keeps the
-- old scroll-prevention behavior.
%foreign "javascript:lambda: _w => { if(window.__irisQueuesReady) return; window.__irisQueuesReady=true; const q=window.__irisEvents=window.__irisEvents||[]; const controller=new AbortController();window.__irisAbort=controller;const on=(target,name,fn,opts={})=>target.addEventListener(name,fn,{...opts,signal:controller.signal}); const enc=s=>Array.from(String(s)).map(c=>c.codePointAt(0)).join('.'); const b=v=>v?'1':'0'; const mods=e=>[b(e.shiftKey),b(e.ctrlKey),b(e.altKey),b(e.metaKey)].join('|'); const push=s=>q.push(s); const key=(a,e)=>push('i1|K|'+a+'|'+enc(e.key)+'|'+enc(e.code||e.key)+'|'+mods(e)+'|'+(Array.from(e.key).length===1?e.key.codePointAt(0):'none')); on(document,'keydown',e=>{ const inField=document.activeElement&&document.activeElement.tagName==='INPUT'; if(!inField&&['ArrowUp','ArrowDown','ArrowLeft','ArrowRight',' '].includes(e.key))e.preventDefault(); key(e.repeat?'repeat':'down',e); }); on(document,'keyup',e=>key('up',e)); const pa={pointerdown:'down',pointerup:'up',pointermove:'move',pointerenter:'enter',pointerleave:'leave',pointercancel:'cancel'}; const pb=n=>n===0?'primary':n===1?'middle':n===2?'secondary':n===3?'back':n===4?'forward':'none'; Object.keys(pa).forEach(name=>on(document,name,e=>push('i1|P|'+pa[name]+'|'+(['mouse','touch','pen'].includes(e.pointerType)?e.pointerType:'mouse')+'|'+Math.max(0,e.pointerId||0)+'|'+e.clientX+'|'+e.clientY+'|'+(e.movementX||0)+'|'+(e.movementY||0)+'|'+pb(e.button)+'|'+Math.max(0,Math.min(1,e.pressure||0))+'|'+mods(e)),{passive:true})); on(document,'wheel',e=>push('i1|S|'+e.clientX+'|'+e.clientY+'|'+e.deltaX+'|'+e.deltaY+'|'+e.deltaZ),{passive:true}); on(window,'resize',()=>push('i1|R|'+innerWidth+'|'+innerHeight)); on(window,'focus',()=>push('i1|F|gain')); on(window,'blur',()=>push('i1|F|lost')); on(window,'orientationchange',()=>push('i1|O|'+(innerHeight>=innerWidth?'portrait':'landscape'))); on(document,'visibilitychange',()=>push('i1|L|'+(document.hidden?'hidden':'visible'))); on(window,'pagehide',()=>push('i1|L|pause')); on(window,'pageshow',()=>push('i1|L|resume')); on(window,'popstate',()=>{push('i1|L|back');push('i1|L|location|'+enc(location.pathname+location.search+location.hash));}); on(document,'compositionstart',e=>push('i1|M|start|'+enc(e.data||''))); on(document,'compositionupdate',e=>push('i1|M|update|'+enc(e.data||''))); on(document,'compositionend',e=>push('i1|M|end|'+enc(e.data||''))); on(document,'click',e=>{const target=e.target&&e.target.closest('[data-iris-click]');if(target&&document.getElementById('iris-app')?.contains(target))push('C'+target.dataset.irisClick);}); on(document,'input',e=>{const target=e.target&&e.target.closest('[data-iris-input]');if(target&&document.getElementById('iris-app')?.contains(target))push('I'+target.dataset.irisInput+'\x01'+target.value);}); push('i1|L|location|'+enc(location.pathname+location.search+location.hash)); if(window.Capacitor&&window.Capacitor.Plugins&&window.Capacitor.Plugins.App){ window.Capacitor.Plugins.App.addListener('backButton',()=>push('i1|L|back')); window.Capacitor.Plugins.App.addListener('pause',()=>push('i1|L|pause')); window.Capacitor.Plugins.App.addListener('resume',()=>push('i1|L|resume')); } }"
prim_setupQueues : PrimIO ()

%foreign "javascript:lambda: _w => { if(window.__irisAbort)window.__irisAbort.abort();window.__irisAbort=null;window.__irisQueuesReady=false;window.__irisEvents=[]; }"
prim_teardownQueues : PrimIO ()

-- Poll one tagged event string from the queue ('' if empty)
%foreign "javascript:lambda: _w => (window.__irisEvents&&window.__irisEvents.length>0)?window.__irisEvents.shift():''"
prim_pollEvent : PrimIO String

-- Schedule a one-shot timeout
%foreign "javascript:lambda: (ms, f, _w) => { const delay=document.hidden ? Math.max(ms,250) : ms; setTimeout(function(){ f(0); }, delay); }"
prim_setTimeout : Int -> IO () -> PrimIO ()

-- ─── IO wrappers ─────────────────────────────────────────────────────────────

injectCSS : String -> IO ()
injectCSS css = primIO (prim_injectCSS css)

setHTML : String -> IO ()
setHTML html = primIO (prim_setHTML html)

setupQueues : IO ()
setupQueues = primIO prim_setupQueues

teardownQueues : IO ()
teardownQueues = primIO prim_teardownQueues

pollEvent : IO String
pollEvent = primIO prim_pollEvent

scheduleIn : Int -> IO () -> IO ()
scheduleIn ms f = primIO (prim_setTimeout ms f)

-- ─── Key → KeyEvent ──────────────────────────────────────────────────────────

domKey : String -> KeyEvent
domKey k =
  let ch = case unpack k of [c] => Just c; _ => Nothing
  in MkKeyEvent KeyDown k k (MkModifiers False False False False) ch

-- ─── Input draining ──────────────────────────────────────────────────────────

-- Separator between a `WInput` event's id and its value, inside an
-- "I<id><sep><value>" tagged queue entry - see the FFI setup above.
sepChar : Char
sepChar = chr 1

splitOnce : Char -> List Char -> (List Char, List Char)
splitOnce sep = go []
  where
    go : List Char -> List Char -> (List Char, List Char)
    go acc []        = (reverse acc, [])
    go acc (c :: cs) = if c == sep then (reverse acc, cs) else go (c :: acc) cs

lookupNat : Nat -> List (Nat, a) -> Maybe a
lookupNat _ []               = Nothing
lookupNat k ((i, v) :: rest) = if k == i then Just v else lookupNat k rest

applyLifecycle : RuntimeControl -> Event -> IO ()
applyLifecycle control (LifecycleEvt PageHidden) = suspendRuntime control
applyLifecycle control (LifecycleEvt AppPaused) = suspendRuntime control
applyLifecycle control (LifecycleEvt PageVisible) = resumeRuntime control
applyLifecycle control (LifecycleEvt AppResumed) = resumeRuntime control
applyLifecycle _ _ = pure ()

handlePlatformEvent : IrisApp mdl msg -> IORef mdl -> RuntimeControl -> Event -> IO ()
handlePlatformEvent app modelRef control event = do
  applyLifecycle control event
  model <- readIORef modelRef
  case app.handleEvent model event of
    Nothing => pure ()
    Just message => dispatchManaged app modelRef control message

-- Drains the ONE ordered event queue, dispatching each entry in the
-- exact order it happened - see this module's doc comment for why that
-- matters (it's the fix for a real edit-then-submit-in-one-frame bug,
-- not just a refactor). Recurses until the queue is empty; `quit`
-- becomes true partway through, later entries in the same batch are
-- correctly skipped rather than dispatched into a model that's about
-- to be torn down.
drainAll : IrisApp mdl outMsg -> IORef mdl -> IORef Bool -> RuntimeControl
         -> IORef (List (Nat, outMsg)) -> IORef (List (Nat, String -> outMsg)) -> IO ()
drainAll app modelRef quitRef control idMapRef inputMapRef = do
  raw <- pollEvent
  case unpack raw of
    []                 => pure ()
    ('i' :: _)         => do
      quit <- readIORef quitRef
      when (not quit) $
        case decodeEvent raw of
          Nothing => pure ()
          Just event => handlePlatformEvent app modelRef control event
      continue
    ('C' :: idChars)   => do
      idMap <- readIORef idMapRef
      quit  <- readIORef quitRef
      when (not quit) $
        case lookupNat (cast {to=Nat} (cast {to=Int} (pack idChars))) idMap of
          Nothing  => pure ()
          Just msg => dispatchManaged app modelRef control msg
      continue
    ('I' :: rest)      => do
      let (idChars, valChars) = splitOnce sepChar rest
      case idChars of
        [] => continue
        _  => do
          inputMap <- readIORef inputMapRef
          quit     <- readIORef quitRef
          when (not quit) $
            case lookupNat (cast {to=Nat} (cast {to=Int} (pack idChars))) inputMap of
              Nothing    => pure ()
              Just toMsg => dispatchManaged app modelRef control (toMsg (pack valChars))
          continue
    _                  => continue -- malformed/unrecognized tag, skip
  where
    continue : IO ()
    continue = drainAll app modelRef quitRef control idMapRef inputMapRef

-- ─── Render loop ─────────────────────────────────────────────────────────────

renderLoop : IrisApp mdl outMsg -> IORef mdl -> IORef Bool -> RuntimeControl
           -> IORef (List (Nat, outMsg)) -> IORef (List (Nat, String -> outMsg)) -> IO ()
renderLoop app modelRef quitRef control idMapRef inputMapRef = do
  quit <- readIORef quitRef
  if quit
    then do
      teardownQueues
      setHTML "<div style='padding:24px;color:#3fb950;font-size:1.2em'>👋 Bye! Refresh to restart.</div>"
    else do
      -- drain input, in true chronological order (see drainAll's doc comment)
      drainAll app modelRef quitRef control idMapRef inputMapRef

      -- render
      quit2 <- readIORef quitRef
      when (not quit2) $ do
        mdl <- readIORef modelRef
        (html, pairs, inputs) <- renderPage (app.view mdl)
        setHTML html
        writeIORef idMapRef pairs
        writeIORef inputMapRef inputs
        scheduleIn 33 (renderLoop app modelRef quitRef control idMapRef inputMapRef)

-- ─── Tick loop ───────────────────────────────────────────────────────────────

tickLoop : IrisApp mdl outMsg -> IORef mdl -> IORef Bool -> RuntimeControl -> Int -> IO ()
tickLoop app modelRef quitRef control ms = do
  quit <- readIORef quitRef
  when (not quit) $ do
    case app.tickMsg of
      Nothing => pure ()
      Just tm => dispatchManaged app modelRef control tm
    scheduleIn ms (tickLoop app modelRef quitRef control ms)

-- ─── runWeb ──────────────────────────────────────────────────────────────────

||| Run an Iris App in the browser using real DOM rendering.
public export
runWeb : IrisApp mdl outMsg -> IO ()
runWeb app = do
  -- inject stylesheet once
  injectCSS irisCSS
  setupQueues

  -- initialise model
  let (initMdl, initCmd) = app.init
  modelRef    <- newIORef initMdl
  quitRef     <- newIORef False
  control     <- newRuntimeControl quitRef
  idMapRef    <- newIORef (the (List (Nat, outMsg)) [])
  inputMapRef <- newIORef (the (List (Nat, String -> outMsg)) [])

  -- run startup commands
  execCmdManaged initCmd (dispatchManaged app modelRef control) control

  -- initial render
  mdl <- readIORef modelRef
  (html, pairs, inputs) <- renderPage (app.view mdl)
  setHTML html
  writeIORef idMapRef pairs
  writeIORef inputMapRef inputs

  -- start loops
  scheduleIn 100 (tickLoop app modelRef quitRef control 100)
  scheduleIn 33  (renderLoop app modelRef quitRef control idMapRef inputMapRef)
