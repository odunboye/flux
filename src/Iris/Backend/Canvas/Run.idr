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
import Iris.App
import Iris.Widget
import Iris.Backend.Terminal.WidgetRender
import Iris.Backend.Canvas.Render
import Iris.Runtime.Common

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

-- Global key queue (same as DOM backend)
%foreign "javascript:lambda: _w => { if(window.__irisKeyListenerReady) return; window.__irisKeyListenerReady=true; window.__irisKeys=window.__irisKeys||[]; document.addEventListener('keydown',function(e){ if(['ArrowUp','ArrowDown','ArrowLeft','ArrowRight',' '].includes(e.key)) e.preventDefault(); window.__irisKeys.push(e.key); }); }"
prim_setupKeys : PrimIO ()

-- Touch gesture recogniser
-- Records touchstart position and on touchend decides the gesture:
--   short swipe up/down  → ArrowUp / ArrowDown
--   short swipe left     → Escape
--   tap (small movement) → ' ' (space = select)
--   swipe right far      → 'a' (add, like a "swipe to add" gesture)
%foreign "javascript:lambda: _w => { if(window.__irisTouchListenerReady) return; window.__irisTouchListenerReady=true; window.__irisKeys=window.__irisKeys||[]; let tx=0,ty=0; document.addEventListener('touchstart',function(e){ if(e.touches.length){ tx=e.touches[0].clientX; ty=e.touches[0].clientY; } },{passive:true}); document.addEventListener('touchend',function(e){ if(!e.changedTouches.length) return; const dx=e.changedTouches[0].clientX-tx; const dy=e.changedTouches[0].clientY-ty; const adx=Math.abs(dx),ady=Math.abs(dy); if(adx<10&&ady<10){ window.__irisKeys.push(' '); } else if(ady>adx){ window.__irisKeys.push(dy<0?'ArrowUp':'ArrowDown'); } else { window.__irisKeys.push(dx<0?'Escape':'a'); } },{passive:true}); }"
prim_setupTouch : PrimIO ()

%foreign "javascript:lambda: _w => (window.__irisKeys&&window.__irisKeys.length>0)?window.__irisKeys.shift():''"
prim_pollKey : PrimIO String

-- ─── Animation loop ──────────────────────────────────────────────────────────

%foreign "javascript:lambda: (f,_w) => { const schedule=()=>{ if(document.hidden){ setTimeout(()=>f(0),250); } else { requestAnimationFrame(()=>f(0)); } }; schedule(); }"
prim_raf : IO () -> PrimIO ()

-- ─── Key dispatch ────────────────────────────────────────────────────────────

domKey : String -> KeyEvent
domKey k =
  let ch = case unpack k of [c] => Just c; _ => Nothing
  in MkKeyEvent KeyDown k k (MkModifiers False False False False) ch

drainKeys : IrisApp mdl outMsg -> IORef mdl -> IORef Bool -> IO ()
drainKeys app modelRef quitRef = do
  k <- primIO prim_pollKey
  case k of
    "" => pure ()
    _  => do
      quit <- readIORef quitRef
      when (not quit) $ do
        m <- readIORef modelRef
        case app.handleEvent m (KeyboardEvent (domKey k)) of
          Nothing  => pure ()
          Just msg => dispatch app modelRef quitRef msg
        drainKeys app modelRef quitRef

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
        -> IORef mdl -> IORef Bool -> IO ()
rafLoop app ctx metric cols rows modelRef quitRef = do
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
      drainKeys app modelRef quitRef
      quit2 <- readIORef quitRef
      when (not quit2) $ do
        mdl <- readIORef modelRef
        renderToCanvas metric (app.view mdl) cols rows ctx
        primIO (prim_raf (rafLoop app ctx metric cols rows modelRef quitRef))

-- ─── runCanvas ───────────────────────────────────────────────────────────────

||| Run with custom canvas selector, cell metric, and virtual dimensions.
public export
runCanvasOn : String -> CanvasMetric -> Nat -> Nat -> IrisApp mdl outMsg -> IO ()
runCanvasOn sel metric cols rows app = do
  primIO (prim_initCanvas sel)
  ctx <- primIO (prim_getCtx sel)

  primIO prim_setupKeys
  primIO prim_setupTouch

  let (initMdl, initCmd) = app.init
  modelRef <- newIORef initMdl
  quitRef  <- newIORef False

  execCmd initCmd (dispatch app modelRef quitRef) quitRef

  -- animation clock (100ms tick for spinners etc.)
  primIO (prim_setTimeout 100 (tickLoop app modelRef quitRef 100))

  -- first frame via RAF
  primIO (prim_raf (rafLoop app ctx metric cols rows modelRef quitRef))

||| Run on an HTML5 Canvas — default desktop settings (80×24 cells, 10×20px).
public export
runCanvas : IrisApp mdl outMsg -> IO ()
runCanvas = runCanvasOn "#iris-canvas" defaultMetric 80 24

||| Run on mobile — larger cells (10×28px) for comfortable touch targets.
public export
runMobile : IrisApp mdl outMsg -> IO ()
runMobile = runCanvasOn "#iris-canvas" mobileMetric 80 24
