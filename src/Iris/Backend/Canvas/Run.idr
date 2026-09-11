||| Iris.Backend.Canvas.Run
||| Platform entry point: runs an Iris App on an HTML5 Canvas.
|||
||| Works in three contexts:
|||   1. Desktop browser  — `<canvas id="iris-canvas">` in a web page
|||   2. Mobile WebView   — same canvas, wrapped by Capacitor (iOS/Android)
|||   3. Electron         — same canvas, wrapped in a desktop window
|||
||| Input handling
||| ─────────────
||| Keyboard events are captured via `document.addEventListener("keydown")`.
||| Touch events are translated to the same KeyEvent.key strings that
||| handleKey already knows:
|||   swipe up/down   → "ArrowUp" / "ArrowDown"
|||   tap (single)    → " "  (space = select/toggle)
|||   swipe left      → "Escape"
|||   long press      → "a"  (add)
|||
||| These mappings feel natural for a list-based app but can be overridden
||| by providing a custom `touchMap` in a future App extension.
module Iris.Backend.Canvas.Run

import Data.IORef
import Iris.State.TEA
import Iris.Platform.Event
import Iris.Core.Types
import Iris.App
import Iris.Widget
import Iris.Backend.Terminal.WidgetRender
import Iris.Backend.Canvas.Render
import Iris.Backend.Canvas.Layout
import Iris.Runtime.Common
import Iris.App.EventWire

-- ─── Canvas acquisition ──────────────────────────────────────────────────────

%foreign "javascript:lambda: (sel,_w) => { const c=document.querySelector(sel); return c ? c.getContext('2d') : null; }"
prim_getCtx : String -> PrimIO AnyPtr

%foreign "javascript:lambda: (sel,_w) => { const c=document.querySelector(sel); return c ? c.clientWidth : 375; }"
prim_canvasClientW : String -> PrimIO Int

%foreign "javascript:lambda: (sel,_w) => { const c=document.querySelector(sel); return c ? c.clientHeight : 812; }"
prim_canvasClientH : String -> PrimIO Int

-- Scale canvas for the device pixel ratio (sharp on Retina / high-DPI)
%foreign "javascript:lambda: (sel,_w) => { const dpr=window.devicePixelRatio||1; const c=document.querySelector(sel); if(c){c.width=c.clientWidth*dpr; c.clientHeight&&(c.height=c.clientHeight*dpr); c.getContext('2d').scale(dpr,dpr);} }"
prim_initCanvas : String -> PrimIO ()

-- ─── Input queues ────────────────────────────────────────────────────────────

-- One ordered, versioned event queue shared by every browser/Capacitor source.
-- Touch gestures also emit compatibility keyboard events until Canvas hit
-- testing replaces the original list-oriented gesture mapping.
%foreign "javascript:lambda: (sel,_w) => { if(window.__irisCanvasEventsReady)return; window.__irisCanvasEventsReady=true; const q=window.__irisCanvasEvents=window.__irisCanvasEvents||[]; const enc=s=>Array.from(String(s)).map(c=>c.codePointAt(0)).join('.'); const b=v=>v?'1':'0'; const mods=e=>[b(e.shiftKey),b(e.ctrlKey),b(e.altKey),b(e.metaKey)].join('|'); const push=s=>q.push(s); const canvas=document.querySelector(sel); const pos=e=>{const r=canvas?canvas.getBoundingClientRect():{left:0,top:0};return [e.clientX-r.left,e.clientY-r.top];}; const key=(name,code=name)=>push('i1|K|down|'+enc(name)+'|'+enc(code)+'|0|0|0|0|'+(Array.from(name).length===1?name.codePointAt(0):'none')); document.addEventListener('keydown',e=>{if(['ArrowUp','ArrowDown','ArrowLeft','ArrowRight',' '].includes(e.key))e.preventDefault();push('i1|K|'+(e.repeat?'repeat':'down')+'|'+enc(e.key)+'|'+enc(e.code||e.key)+'|'+mods(e)+'|'+(Array.from(e.key).length===1?e.key.codePointAt(0):'none'));}); document.addEventListener('keyup',e=>push('i1|K|up|'+enc(e.key)+'|'+enc(e.code||e.key)+'|'+mods(e)+'|'+(Array.from(e.key).length===1?e.key.codePointAt(0):'none'))); const pa={pointerdown:'down',pointerup:'up',pointermove:'move',pointerenter:'enter',pointerleave:'leave',pointercancel:'cancel'}; const pb=n=>n===0?'primary':n===1?'middle':n===2?'secondary':n===3?'back':n===4?'forward':'none'; Object.keys(pa).forEach(name=>canvas&&canvas.addEventListener(name,e=>push('i1|P|'+pa[name]+'|'+(['mouse','touch','pen'].includes(e.pointerType)?e.pointerType:'mouse')+'|'+Math.max(0,e.pointerId||0)+'|'+pos(e)[0]+'|'+pos(e)[1]+'|'+(e.movementX||0)+'|'+(e.movementY||0)+'|'+pb(e.button)+'|'+Math.max(0,Math.min(1,e.pressure||0))+'|'+mods(e)),{passive:true})); canvas&&canvas.addEventListener('wheel',e=>push('i1|S|'+e.clientX+'|'+e.clientY+'|'+e.deltaX+'|'+e.deltaY+'|'+e.deltaZ),{passive:true}); addEventListener('resize',()=>push('i1|R|'+innerWidth+'|'+innerHeight)); addEventListener('focus',()=>push('i1|F|gain')); addEventListener('blur',()=>push('i1|F|lost')); addEventListener('orientationchange',()=>push('i1|O|'+(innerHeight>=innerWidth?'portrait':'landscape'))); document.addEventListener('visibilitychange',()=>push('i1|L|'+(document.hidden?'hidden':'visible'))); addEventListener('pagehide',()=>push('i1|L|pause')); addEventListener('pageshow',()=>push('i1|L|resume')); addEventListener('popstate',()=>{push('i1|L|back');push('i1|L|location|'+enc(location.pathname+location.search+location.hash));}); document.addEventListener('compositionstart',e=>push('i1|M|start|'+enc(e.data||''))); document.addEventListener('compositionupdate',e=>push('i1|M|update|'+enc(e.data||''))); document.addEventListener('compositionend',e=>push('i1|M|end|'+enc(e.data||''))); let tx=0,ty=0; document.addEventListener('touchstart',e=>{if(e.touches.length){tx=e.touches[0].clientX;ty=e.touches[0].clientY;}},{passive:true}); document.addEventListener('touchend',e=>{if(!e.changedTouches.length)return;const dx=e.changedTouches[0].clientX-tx,dy=e.changedTouches[0].clientY-ty,ax=Math.abs(dx),ay=Math.abs(dy);if(ax<10&&ay<10)key(' ');else if(ay>ax)key(dy<0?'ArrowUp':'ArrowDown');else key(dx<0?'Escape':'a');},{passive:true}); push('i1|L|location|'+enc(location.pathname+location.search+location.hash)); if(window.Capacitor&&window.Capacitor.Plugins&&window.Capacitor.Plugins.App){window.Capacitor.Plugins.App.addListener('backButton',()=>push('i1|L|back'));window.Capacitor.Plugins.App.addListener('pause',()=>push('i1|L|pause'));window.Capacitor.Plugins.App.addListener('resume',()=>push('i1|L|resume'));} }"
prim_setupEvents : String -> PrimIO ()

%foreign "javascript:lambda: _w => (window.__irisCanvasEvents&&window.__irisCanvasEvents.length>0)?window.__irisCanvasEvents.shift():''"
prim_pollEvent : PrimIO String

-- ─── Animation loop ──────────────────────────────────────────────────────────

%foreign "javascript:lambda: (f,_w) => { const schedule=()=>{ if(document.hidden){ setTimeout(()=>f(0),250); } else { requestAnimationFrame(()=>f(0)); } }; schedule(); }"
prim_raf : IO () -> PrimIO ()

-- ─── Key dispatch ────────────────────────────────────────────────────────────

activateTarget : IrisApp mdl msg -> IORef mdl -> IORef Bool -> HitTarget msg -> IO ()
activateTarget app modelRef quitRef (ActivateTarget _ _ message) =
  dispatch app modelRef quitRef message
activateTarget _ _ _ (InputTarget _ _ _ _) = pure ()

pointerCell : CanvasMetric -> Point -> Maybe (Nat, Nat)
pointerCell metric point =
  if point.x < 0.0 || point.y < 0.0 then Nothing
  else Just (cast (point.x / metric.cellW), cast (point.y / metric.cellH))

handleCanvasEvent : IrisApp mdl msg -> CanvasMetric -> IORef mdl -> IORef Bool
                 -> IORef (List (HitTarget msg)) -> IORef (Maybe Nat) -> Event -> IO ()
handleCanvasEvent app metric modelRef quitRef targetsRef captureRef event = do
  model <- readIORef modelRef
  case app.handleEvent model event of
    Nothing => pure ()
    Just message => dispatch app modelRef quitRef message
  case event of
    PointerEvt pointer =>
      case pointerCell metric pointer.position of
        Nothing => writeIORef captureRef Nothing
        Just (col, row) => do
          targets <- readIORef targetsRef
          case pointer.action of
            PointerDown =>
              case hitAt col row targets of
                Nothing => writeIORef captureRef Nothing
                Just target => writeIORef captureRef (Just (targetId target))
            PointerCancel => writeIORef captureRef Nothing
            PointerUp => do
              captured <- readIORef captureRef
              writeIORef captureRef Nothing
              case (captured, hitAt col row targets) of
                (Just expected, Just target) =>
                  when (expected == targetId target) $
                    activateTarget app modelRef quitRef target
                _ => pure ()
            _ => pure ()
    _ => pure ()

drainEvents : IrisApp mdl msg -> CanvasMetric -> IORef mdl -> IORef Bool
           -> IORef (List (HitTarget msg)) -> IORef (Maybe Nat) -> IO ()
drainEvents app metric modelRef quitRef targetsRef captureRef = do
  raw <- primIO prim_pollEvent
  case raw of
    "" => pure ()
    _ => do
      quit <- readIORef quitRef
      when (not quit) $
        case decodeEvent raw of
          Nothing => pure ()
          Just event => handleCanvasEvent app metric modelRef quitRef
                          targetsRef captureRef event
      drainEvents app metric modelRef quitRef targetsRef captureRef

-- ─── Tick loop (animation clock) ─────────────────────────────────────────────

%foreign "javascript:lambda: (ms,f,_w) => setTimeout(function(){ f(0); },ms)"
prim_setTimeout : Int -> IO () -> PrimIO ()

tickLoop : IrisApp mdl outMsg -> IORef mdl -> IORef Bool -> Int -> IO ()
tickLoop app modelRef quitRef ms = do
  quit <- readIORef quitRef
  when (not quit) $ do
    case app.tickMsg of
      Nothing => pure ()
      Just tm => dispatch app modelRef quitRef tm
    primIO (prim_setTimeout ms (tickLoop app modelRef quitRef ms))

-- ─── Main render / event loop (requestAnimationFrame) ────────────────────────

rafLoop : IrisApp mdl outMsg -> AnyPtr -> CanvasMetric -> Nat -> Nat
        -> IORef mdl -> IORef Bool -> IORef (List (HitTarget outMsg))
        -> IORef (Maybe Nat) -> IO ()
rafLoop app ctx metric cols rows modelRef quitRef targetsRef captureRef = do
  quit <- readIORef quitRef
  if quit
    then do
      -- goodbye frame
      primIO (prim_setFill "#0d1117" ctx)
      primIO (prim_fillRect 0.0 0.0
              (cast cols * metric.cellW) (cast rows * metric.cellH) ctx)
      primIO (prim_setFill "#3fb950" ctx)
      primIO (prim_setFont (metric.fontSz * 1.2) True False metric.font ctx)
      primIO (prim_fillText "👋 Bye! Refresh to restart."
              (metric.cellW * 2.0) (metric.cellH * 3.0) 0.0 ctx)
    else do
      drainEvents app metric modelRef quitRef targetsRef captureRef
      quit2 <- readIORef quitRef
      when (not quit2) $ do
        mdl <- readIORef modelRef
        let widget = app.view mdl
        writeIORef targetsRef (layoutTargets widget cols rows)
        renderToCanvas metric widget cols rows ctx
        primIO (prim_raf (rafLoop app ctx metric cols rows modelRef quitRef
                              targetsRef captureRef))

-- ─── runCanvas ───────────────────────────────────────────────────────────────

||| Run with custom canvas selector, cell metric, and virtual dimensions.
public export
runCanvasOn : String -> CanvasMetric -> Nat -> Nat -> IrisApp mdl outMsg -> IO ()
runCanvasOn sel metric cols rows app = do
  primIO (prim_initCanvas sel)
  ctx <- primIO (prim_getCtx sel)

  primIO (prim_setupEvents sel)

  let (initMdl, initCmd) = app.init
  modelRef   <- newIORef initMdl
  quitRef    <- newIORef False
  targetsRef <- newIORef (layoutTargets (app.view initMdl) cols rows)
  captureRef <- newIORef (the (Maybe Nat) Nothing)

  execCmd initCmd (dispatch app modelRef quitRef) quitRef

  -- animation clock (100ms tick for spinners etc.)
  primIO (prim_setTimeout 100 (tickLoop app modelRef quitRef 100))

  -- first frame via RAF
  primIO (prim_raf (rafLoop app ctx metric cols rows modelRef quitRef
                            targetsRef captureRef))

||| Run on an HTML5 Canvas — default desktop settings (80×24 cells, 10×20px).
public export
runCanvas : IrisApp mdl outMsg -> IO ()
runCanvas = runCanvasOn "#iris-canvas" defaultMetric 80 24

||| Run on mobile — larger cells (10×28px) for comfortable touch targets.
public export
runMobile : IrisApp mdl outMsg -> IO ()
runMobile = runCanvasOn "#iris-canvas" mobileMetric 80 24
