||| Flux.UI.Backend.Canvas.Render
||| Renders an abstract Widget tree onto an HTML5 Canvas 2D context.
|||
||| Why Canvas (not DOM)?
||| ────────────────────
||| Flux UI owns the drawing pipeline — just like it owns the ANSI pipeline for
||| the TUI backend.  Canvas gives us:
|||   • pixel-perfect rendering, same on desktop browser + mobile WebView
|||   • 60 fps via requestAnimationFrame
|||   • zero CSS layout surprises on small / constrained screens
|||   • a clear path to native (Android Canvas, iOS Core Graphics) later
|||
||| Architecture
||| ────────────
|||   1. Re-use the Widget layout pass from WidgetRender (pure Idris2).
|||   2. Walk the laid-out tree and emit Canvas2D draw calls via JS FFI.
|||   3. A touch-event layer translates swipe/tap → the same KeyEvent names
|||      that handleKey already understands.
module Flux.UI.Backend.Canvas.Render

import Flux.UI.Widget
import Flux.UI.Backend.Terminal.WidgetRender  -- reuse measure / WSize / WRect

-- ─── Cell metric ─────────────────────────────────────────────────────────────
-- We express Widget sizes in abstract "cells" (same unit as the TUI renderer).
-- The canvas renderer multiplies by (cellW, cellH) to get CSS pixels.
-- On mobile the cell is slightly taller to give comfortable touch targets.

public export
record CanvasMetric where
  constructor MkMetric
  cellW  : Double   -- pixels per cell column
  cellH  : Double   -- pixels per cell row
  fontSz : Double   -- CSS font-size in px
  font   : String   -- CSS font-family

public export
defaultMetric : CanvasMetric
defaultMetric = MkMetric 10.0 20.0 14.0
  "-apple-system, BlinkMacSystemFont, 'Segoe UI', Menlo, monospace"

public export
mobileMetric : CanvasMetric
mobileMetric = MkMetric 10.0 28.0 16.0
  "-apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif"

-- ─── Colour mapping ──────────────────────────────────────────────────────────

fluxUIToCSS : UIColor -> String
fluxUIToCSS Inherit       = "#c9d1d9"
fluxUIToCSS (IRGB r g b)  = "rgb(" ++ show r ++ "," ++ show g ++ "," ++ show b ++ ")"
fluxUIToCSS IBlue         = "#58a6ff"
fluxUIToCSS IRed          = "#ff7b72"
fluxUIToCSS IGreen        = "#3fb950"
fluxUIToCSS IYellow       = "#d29922"
fluxUIToCSS ICyan         = "#39c5cf"
fluxUIToCSS IMagenta      = "#bc8cff"
fluxUIToCSS IWhite        = "#f0f6fc"
fluxUIToCSS IBlack        = "#0d1117"
fluxUIToCSS IGray         = "#8b949e"
fluxUIToCSS ILightBlue    = "#79c0ff"
fluxUIToCSS ILightGreen   = "#56d364"
fluxUIToCSS ILightRed     = "#ffa198"
fluxUIToCSS ILightYellow  = "#e3b341"
fluxUIToCSS IDarkBlue     = "#1f6feb"
fluxUIToCSS IDarkGray     = "#6e7681"

-- ─── JS Canvas2D FFI ─────────────────────────────────────────────────────────

-- All draw calls take `ctx : AnyPtr` (the CanvasRenderingContext2D) and
-- the world value.  The canvas coordinate system uses CSS pixels.

%foreign "javascript:lambda: (ctx,_w) => { ctx.save(); }"
prim_save : AnyPtr -> PrimIO ()

%foreign "javascript:lambda: (ctx,_w) => { ctx.restore(); }"
prim_restore : AnyPtr -> PrimIO ()

%foreign "javascript:lambda: (color,ctx,_w) => { ctx.fillStyle=color; }"
public export
prim_setFill : String -> AnyPtr -> PrimIO ()

%foreign "javascript:lambda: (color,ctx,_w) => { ctx.strokeStyle=color; }"
prim_setStroke : String -> AnyPtr -> PrimIO ()

%foreign "javascript:lambda: (w,ctx,_w) => { ctx.lineWidth=w; }"
prim_setLineWidth : Double -> AnyPtr -> PrimIO ()

%foreign "javascript:lambda: (x,y,w,h,ctx,_w) => { ctx.fillRect(x,y,w,h); }"
public export
prim_fillRect : Double -> Double -> Double -> Double -> AnyPtr -> PrimIO ()

%foreign "javascript:lambda: (x,y,w,h,r,ctx,_w) => { ctx.beginPath(); ctx.roundRect(x,y,w,h,r); ctx.fill(); }"
prim_fillRoundRect : Double -> Double -> Double -> Double -> Double -> AnyPtr -> PrimIO ()

%foreign "javascript:lambda: (x,y,w,h,r,ctx,_w) => { ctx.beginPath(); ctx.roundRect(x,y,w,h,r); ctx.stroke(); }"
prim_strokeRoundRect : Double -> Double -> Double -> Double -> Double -> AnyPtr -> PrimIO ()

%foreign "javascript:lambda: (x,y,w,h,ctx,_w) => { ctx.strokeRect(x,y,w,h); }"
prim_strokeRect : Double -> Double -> Double -> Double -> AnyPtr -> PrimIO ()

%foreign "javascript:lambda: (text,x,y,maxW,ctx,_w) => { ctx.fillText(text,x,y,maxW>0?maxW:undefined); }"
public export
prim_fillText : String -> Double -> Double -> Double -> AnyPtr -> PrimIO ()

%foreign "javascript:lambda: (sz,bold,italic,family,ctx,_w) => { ctx.font=(bold?'bold ':'')+( italic?'italic ':'')+sz+'px '+family; }"
public export
prim_setFont : Double -> Bool -> Bool -> String -> AnyPtr -> PrimIO ()

%foreign "javascript:lambda: (text,ctx,_w) => ctx.measureText(text).width"
prim_measureText : String -> AnyPtr -> PrimIO Double

%foreign "javascript:lambda: (x1,y1,x2,y2,ctx,_w) => { ctx.beginPath(); ctx.moveTo(x1,y1); ctx.lineTo(x2,y2); ctx.stroke(); }"
prim_drawLine : Double -> Double -> Double -> Double -> AnyPtr -> PrimIO ()

%foreign "javascript:lambda: (x,y,w,h,ctx,_w) => { ctx.clearRect(x,y,w,h); }"
prim_clearRect : Double -> Double -> Double -> Double -> AnyPtr -> PrimIO ()

%foreign "javascript:lambda: (x,y,w,h,ctx,_w) => { ctx.beginPath(); ctx.rect(x,y,w,h); ctx.clip(); }"
prim_clip : Double -> Double -> Double -> Double -> AnyPtr -> PrimIO ()

%foreign "javascript:lambda: (x,y,ctx,_w) => { ctx.translate(x,y); }"
prim_translate : Double -> Double -> AnyPtr -> PrimIO ()

-- ─── IO wrappers ─────────────────────────────────────────────────────────────

cSave    : AnyPtr -> IO () ; cSave    ctx = primIO (prim_save ctx)
cRestore : AnyPtr -> IO () ; cRestore ctx = primIO (prim_restore ctx)

cFill   : String -> AnyPtr -> IO () ; cFill   c ctx = primIO (prim_setFill c ctx)
cStroke : String -> AnyPtr -> IO () ; cStroke c ctx = primIO (prim_setStroke c ctx)
cLW     : Double -> AnyPtr -> IO () ; cLW     w ctx = primIO (prim_setLineWidth w ctx)

cFillRect   : Double -> Double -> Double -> Double -> AnyPtr -> IO ()
cFillRect x y w h ctx = primIO (prim_fillRect x y w h ctx)

cFillRound  : Double -> Double -> Double -> Double -> Double -> AnyPtr -> IO ()
cFillRound x y w h r ctx = primIO (prim_fillRoundRect x y w h r ctx)

cStrokeRound : Double -> Double -> Double -> Double -> Double -> AnyPtr -> IO ()
cStrokeRound x y w h r ctx = primIO (prim_strokeRoundRect x y w h r ctx)

cText : String -> Double -> Double -> Double -> AnyPtr -> IO ()
cText t x y mw ctx = primIO (prim_fillText t x y mw ctx)

cFont : Double -> Bool -> Bool -> String -> AnyPtr -> IO ()
cFont sz b i f ctx = primIO (prim_setFont sz b i f ctx)

cLine : Double -> Double -> Double -> Double -> AnyPtr -> IO ()
cLine x1 y1 x2 y2 ctx = primIO (prim_drawLine x1 y1 x2 y2 ctx)

cClear : Double -> Double -> Double -> Double -> AnyPtr -> IO ()
cClear x y w h ctx = primIO (prim_clearRect x y w h ctx)

cClip : Double -> Double -> Double -> Double -> AnyPtr -> IO ()
cClip x y w h ctx = primIO (prim_clip x y w h ctx)

cTranslate : Double -> Double -> AnyPtr -> IO ()
cTranslate x y ctx = primIO (prim_translate x y ctx)

-- ─── Coordinate helpers ──────────────────────────────────────────────────────

-- Convert cell units to CSS pixels
cx : CanvasMetric -> Nat -> Double
cx m n = cast n * m.cellW

cy : CanvasMetric -> Nat -> Double
cy m n = cast n * m.cellH

cw : CanvasMetric -> Nat -> Double
cw = cx

ch : CanvasMetric -> Nat -> Double
ch = cy

-- ─── Spinner frames ──────────────────────────────────────────────────────────

spinFrameC : Nat -> String
spinFrameC n =
  let frames = ["⠋","⠙","⠹","⠸","⠼","⠴","⠦","⠧","⠇","⠏"]
      idx = cast {to=Nat} (cast {to=Int} n `mod` 10)
  in case getAt idx frames of Nothing => "⠋"; Just s => s
  where
    getAt : Nat -> List a -> Maybe a
    getAt _     []       = Nothing
    getAt Z     (x :: _) = Just x
    getAt (S k) (_ :: xs)= getAt k xs

-- ─── Progress bar ────────────────────────────────────────────────────────────

drawProgressBar : CanvasMetric -> WRect -> Double -> AnyPtr -> IO ()
drawProgressBar m r frac ctx = do
  let px = cx m r.col
      py = cy m r.row + m.cellH * 0.35
      pw = cw m r.w
      ph = m.cellH * 0.3
      filledW = pw * frac
      pct = show (cast {to=Int} (frac * 100.0)) ++ "%"
  -- track
  cFill "#21262d" ctx
  cFillRound px py pw ph 3.0 ctx
  -- fill
  cFill "#1f6feb" ctx
  cFillRound px py filledW ph 3.0 ctx
  -- label
  cFill "#8b949e" ctx
  cFont (m.fontSz * 0.85) False False m.font ctx
  cText pct (px + pw + 6.0) (py + ph) 0.0 ctx

-- ─── Sparkline ───────────────────────────────────────────────────────────────

sparkBarChars : List Char
sparkBarChars = ['▁','▂','▃','▄','▅','▆','▇','█']

sparkCharC : Double -> String
sparkCharC v =
  let idx = cast {to=Nat} (cast {to=Int} (v * 7.0)) `min` 7
  in case getAt idx sparkBarChars of Nothing => "▁"; Just c => pack [c]
  where
    getAt : Nat -> List a -> Maybe a
    getAt _     []       = Nothing
    getAt Z     (x :: _) = Just x
    getAt (S k) (_ :: xs)= getAt k xs

listTakeC : Nat -> List a -> List a
listTakeC Z     _        = []
listTakeC _     []       = []
listTakeC (S n) (x :: xs)= x :: listTakeC n xs

wrapChars : Nat -> List Char -> List String
wrapChars Z chars = [pack chars]
wrapChars _ [] = []
wrapChars width chars =
  let (line, rest) = takeChunk width chars
  in pack line :: wrapChars width rest
  where
    takeChunk : Nat -> List Char -> (List Char, List Char)
    takeChunk Z remaining = ([], remaining)
    takeChunk _ [] = ([], [])
    takeChunk (S count) (char :: remaining) =
      let (line, rest) = takeChunk count remaining in (char :: line, rest)

renderWrappedLines : CanvasMetric -> List String -> Double -> Double
                  -> Double -> AnyPtr -> IO ()
renderWrappedLines _ [] _ _ _ _ = pure ()
renderWrappedLines metric (line :: rest) x y width ctx = do
  cText line x y width ctx
  renderWrappedLines metric rest x (y + metric.cellH) width ctx

-- ─── Main widget renderer ────────────────────────────────────────────────────

mutual

 ||| Render one widget at the given WRect onto the canvas context.
 public export
 renderOnCanvas : CanvasMetric -> Widget msg -> WRect -> AnyPtr -> IO ()

 renderOnCanvas m (WText s str) r ctx = do
  let x  = cx m r.col + cx m s.padH
      y  = cy m r.row  + m.cellH * 0.75   -- baseline offset
      fw = cw m (r.w `minus` 2 * s.padH)
  -- background fill
  case s.bg of
    Nothing => pure ()
    Just c  => do
      cFill (fluxUIToCSS c) ctx
      cFillRect (cx m r.col) (cy m r.row) (cw m r.w) (ch m r.h) ctx
  -- border
  case s.border of
    NoBorder => pure ()
    b        => do
      let bcolour = case b of ThickBorder => "#58a6ff"; _ => "#30363d"
          bwidth  = case b of ThickBorder => 2.0;       _ => 1.0
          brad    = case b of RoundedBorder => 6.0;     _ => 4.0
      cStroke bcolour ctx
      cLW bwidth ctx
      cStrokeRound (cx m r.col + 0.5) (cy m r.row + 0.5)
                   (cw m r.w - 1.0) (ch m r.h - 1.0) brad ctx
  -- title label above top border
  case s.label of
    Nothing => pure ()
    Just t  => do
      cFill (fluxUIToCSS IGray) ctx
      cFont (m.fontSz * 0.8) True False m.font ctx
      cText t (cx m r.col + 8.0) (cy m r.row - 2.0) 0.0 ctx
  -- text
  let fgCol = case s.fg of Nothing => "#c9d1d9"; Just c => fluxUIToCSS c
  cFill fgCol ctx
  cFont m.fontSz s.bold s.italic m.font ctx
  cText str x y fw ctx

 renderOnCanvas m (WWrapText s str) r ctx = do
  let ir = innerRect s r
      fgCol = case s.fg of Nothing => "#c9d1d9"; Just color => fluxUIToCSS color
      lines = wrapChars (max 1 ir.w) (unpack str)
  cFill fgCol ctx
  cFont m.fontSz s.bold s.italic m.font ctx
  cSave ctx
  cClip (cx m ir.col) (cy m ir.row) (cw m ir.w) (ch m ir.h) ctx
  renderWrappedLines m lines (cx m ir.col) (cy m ir.row + m.cellH * 0.75)
    (cw m ir.w) ctx
  cRestore ctx

 renderOnCanvas m (WScroll s scrollX scrollY child) r ctx = do
  renderBox m s r ctx
  let ir = innerRect s r
      contentSize = measure child 10000 10000
  cSave ctx
  cClip (cx m ir.col) (cy m ir.row) (cw m ir.w) (ch m ir.h) ctx
  cTranslate (-(cx m scrollX)) (-(cy m scrollY)) ctx
  renderOnCanvas m child (MkWRect ir.col ir.row contentSize.w contentSize.h) ctx
  cRestore ctx

 renderOnCanvas m (WVStack s children) r ctx = do
  renderBox m s r ctx
  let ir    = innerRect s r
      sizes = distributeV children ir.w ir.h
  cSave ctx
  cClip (cx m ir.col) (cy m ir.row) (cw m ir.w) (ch m ir.h) ctx
  renderVKidsC m children sizes ir.col ir.row ir.w ir.h ctx
  cRestore ctx

 renderOnCanvas m (WHStack s children) r ctx = do
  renderBox m s r ctx
  let ir    = innerRect s r
      sizes = distributeH children ir.w ir.h
  cSave ctx
  cClip (cx m ir.col) (cy m ir.row) (cw m ir.w) (ch m ir.h) ctx
  renderHKidsC m children sizes ir.col ir.row ir.w ir.h ctx
  cRestore ctx

 renderOnCanvas m (WProgress s frac) r ctx = do
  let ir = innerRect s r
  drawProgressBar m ir frac ctx

 renderOnCanvas m (WSpinner s tick) r ctx = do
  let ir    = innerRect s r
      frame = spinFrameC tick
      fgCol = case s.fg of Nothing => "#8b949e"; Just c => fluxUIToCSS c
  cFill fgCol ctx
  cFont m.fontSz False False m.font ctx
  cText (frame ++ " working") (cx m ir.col) (cy m ir.row + m.cellH * 0.75) 0.0 ctx

 renderOnCanvas m (WSparkline s vals) r ctx = do
  let ir    = innerRect s r
      chars = concat (map sparkCharC (listTakeC ir.w vals))
      fgCol = case s.fg of Nothing => "#3fb950"; Just c => fluxUIToCSS c
  cFill fgCol ctx
  cFont m.fontSz False False m.font ctx
  cText chars (cx m ir.col) (cy m ir.row + m.cellH * 0.75) 0.0 ctx

 renderOnCanvas m (WInput s val _) r ctx = do
  let ir = innerRect s r
      border = fluxUIToCSS $ case s.bg of Nothing => IBlack; Just c => c
  -- box
  cFill "#0d1117" ctx
  cFillRound (cx m r.col) (cy m r.row)
             (cw m r.w) (ch m r.h) 4.0 ctx
  cStroke "#30363d" ctx
  cLW 1.0 ctx
  cStrokeRound (cx m r.col + 0.5) (cy m r.row + 0.5)
               (cw m r.w - 1.0) (ch m r.h - 1.0) 4.0 ctx
  -- text + cursor
  cFill "#c9d1d9" ctx
  cFont m.fontSz False False m.font ctx
  cText val (cx m ir.col) (cy m ir.row + m.cellH * 0.75) (cw m ir.w) ctx
  -- blinking cursor placeholder (always on for now)
  let cursorX = cx m ir.col + cast (length val) * m.cellW * 0.6
  cFill "#58a6ff" ctx
  cFillRect cursorX (cy m ir.row + 4.0) 2.0 (m.cellH - 8.0) ctx

 renderOnCanvas m (WButton s lbl _) r ctx = do
  let bgCol = case s.bg of Nothing => "#21262d"; Just c => fluxUIToCSS c
      fgCol = case s.fg of Nothing => "#c9d1d9"; Just c => fluxUIToCSS c
  cFill bgCol ctx
  cFillRound (cx m r.col) (cy m r.row) (cw m r.w) (ch m r.h) 6.0 ctx
  cStroke "#30363d" ctx
  cLW 1.0 ctx
  cStrokeRound (cx m r.col + 0.5) (cy m r.row + 0.5)
               (cw m r.w - 1.0) (ch m r.h - 1.0) 6.0 ctx
  cFill fgCol ctx
  cFont m.fontSz s.bold s.italic m.font ctx
  cText lbl (cx m r.col + cw m s.padH + 8.0)
            (cy m r.row + m.cellH * 0.75) 0.0 ctx

 renderOnCanvas m (WCheckbox s checked _) r ctx = do
  let x = cx m r.col
      y = cy m r.row + m.cellH * 0.15
      sz = m.cellH * 0.7
  -- box
  cFill "#21262d" ctx
  cFillRound x y sz sz 3.0 ctx
  cStroke "#30363d" ctx
  cLW 1.0 ctx
  cStrokeRound (x+0.5) (y+0.5) (sz-1.0) (sz-1.0) 3.0 ctx
  -- check mark
  when checked $ do
    cFill "#58a6ff" ctx
    cFillRound x y sz sz 3.0 ctx
    cFill "#0d1117" ctx
    cFont (sz * 0.9) True False m.font ctx
    cText "✓" (x + sz*0.15) (y + sz*0.85) 0.0 ctx

 renderOnCanvas _ WSpacer _ _ = pure ()

 renderOnCanvas m (WDivider s) r ctx = do
  let y   = cy m r.row + m.cellH * 0.5
      col = case s.fg of Nothing => "#30363d"; Just c => fluxUIToCSS c
  cStroke col ctx
  cLW 1.0 ctx
  cLine (cx m r.col) y (cx m r.col + cw m r.w) y ctx

 -- ─── Box background helper ───────────────────────────────────────────────────

 renderBox : CanvasMetric -> Style -> WRect -> AnyPtr -> IO ()
 renderBox m s r ctx = do
  case s.bg of
    Nothing => pure ()
    Just c  => do
      cFill (fluxUIToCSS c) ctx
      cFillRect (cx m r.col) (cy m r.row) (cw m r.w) (ch m r.h) ctx
  case s.border of
    NoBorder => pure ()
    b        => do
      let bc   = case b of ThickBorder => "#58a6ff"; _ => "#30363d"
          bw   = case b of ThickBorder => 2.0; _ => 1.0
          brad = case b of RoundedBorder => 6.0; _ => 4.0
      cStroke bc ctx; cLW bw ctx
      cStrokeRound (cx m r.col + 0.5) (cy m r.row + 0.5)
                   (cw m r.w - 1.0)   (ch m r.h - 1.0) brad ctx
  case s.label of
    Nothing => pure ()
    Just t  => do
      cFill (fluxUIToCSS IGray) ctx
      cFont (m.fontSz * 0.8) True False m.font ctx
      cText t (cx m r.col + 8.0) (cy m r.row - 2.0) 0.0 ctx

 -- ─── Stack rendering helpers ─────────────────────────────────────────────────

 renderVKidsC : CanvasMetric -> List (Widget msg) -> List WSize
             -> Nat -> Nat -> Nat -> Nat -> AnyPtr -> IO ()
 renderVKidsC _ []         _          _   _   _    _    _ = pure ()
 renderVKidsC m (c :: cs) (sz :: szs) col row maxW maxH ctx =
  let cw' = if widgetFillH c then maxW else min sz.w maxW
      ch' = sz.h
  in do renderOnCanvas m c (MkWRect col row cw' ch') ctx
        renderVKidsC m cs szs col (row + ch') maxW (maxH `minus` ch') ctx
 renderVKidsC m (_ :: cs) [] col row maxW maxH ctx =
  renderVKidsC m cs [] col row maxW maxH ctx

 renderHKidsC : CanvasMetric -> List (Widget msg) -> List WSize
             -> Nat -> Nat -> Nat -> Nat -> AnyPtr -> IO ()
 renderHKidsC _ []         _          _   _   _    _    _ = pure ()
 renderHKidsC m (c :: cs) (sz :: szs) col row maxW maxH ctx =
  let cw' = sz.w
      ch' = if widgetFillV c then maxH else min sz.h maxH
  in do renderOnCanvas m c (MkWRect col row cw' ch') ctx
        renderHKidsC m cs szs (col + cw') row (maxW `minus` cw') maxH ctx
 renderHKidsC m (_ :: cs) [] col row maxW maxH ctx =
  renderHKidsC m cs [] col row maxW maxH ctx

-- ─── Top-level render ────────────────────────────────────────────────────────

||| Render the full Widget tree onto a Canvas context.
||| `colsW` / `rowsH` are the root widget's dimensions in cells.
public export
renderToCanvas : CanvasMetric -> Widget msg -> Nat -> Nat -> AnyPtr -> IO ()
renderToCanvas m w colsW rowsH ctx = do
  cClear 0.0 0.0 (cast colsW * m.cellW) (cast rowsH * m.cellH) ctx
  renderOnCanvas m w (MkWRect 0 0 colsW rowsH) ctx
