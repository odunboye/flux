||| Iris.Backend.Terminal.Runtime
||| Full TUI backend — assembles the PAL record for terminal rendering.
module Iris.Backend.Terminal.Runtime

import Data.IORef
import Iris.Core.Types
import Iris.Render.Types
import Iris.Platform.Interface
import Iris.Platform.Event
import Iris.Backend.Terminal.Types
import Iris.Backend.Terminal.ANSI
import Iris.Backend.Terminal.Diff
import Iris.Backend.Terminal.Input
import Iris.State.TEA

-- ─── Local helpers ───────────────────────────────────────────────────────────

rtRange : Nat -> Nat -> List Nat
rtRange lo hi = go lo []
  where
    go : Nat -> List Nat -> List Nat
    go i acc =
      if i >= hi then reverse acc
      else go (i + 1) (i :: acc)

rtZip : List x -> List y -> List (x, y)
rtZip []       _        = []
rtZip _        []       = []
rtZip (x::xs) (y::ys)  = (x,y) :: rtZip xs ys

rtZipIdx : List val -> List (Nat, val)
rtZipIdx xs = rtZip (rtRange 0 (length xs)) xs

rtProduct : List x -> List y -> List (x, y)
rtProduct xs ys = concatMap (\x => map (\y => (x, y)) ys) xs

-- ─── Terminal runtime state ──────────────────────────────────────────────────

record TermState where
  constructor MkTermState
  frontBuf   : CellBuffer
  backBuf    : CellBuffer
  termSize   : TermSize
  firstFrame : Bool

-- ─── Low-level IO stubs ──────────────────────────────────────────────────────

termWrite : String -> IO ()
termWrite s = putStr s

termFlush : IO ()
termFlush = pure ()

queryTermSize : IO TermSize
queryTermSize = pure (MkTermSize 80 24)

enableRawMode : IO ()
enableRawMode = pure ()

disableRawMode : IO ()
disableRawMode = pure ()

readStdinNonBlocking : IO String
readStdinNonBlocking = pure ""

-- ─── Cell draw helpers ───────────────────────────────────────────────────────

drawCell : IORef TermState -> Nat -> Nat -> Cell -> IO ()
drawCell stRef c r cell = do
  st <- readIORef stRef
  writeIORef stRef ({ backBuf $= (\buf => setCell buf c r cell) } st)

-- ─── Renderer implementation ─────────────────────────────────────────────────

termBeginFrame : IORef TermState -> IO ()
termBeginFrame stRef = do
  st <- readIORef stRef
  let blank = emptyBuffer st.termSize.cols st.termSize.rows
  writeIORef stRef ({ backBuf := blank } st)

termEndFrame : IORef TermState -> IO ()
termEndFrame stRef = do
  st <- readIORef stRef
  let output = if st.firstFrame
                 then fullRedraw st.backBuf
                 else diffBuffers st.frontBuf st.backBuf
  termWrite output
  termFlush
  writeIORef stRef ({ frontBuf := st.backBuf, firstFrame := False } st)

termSubmitCall : IORef TermState -> DrawCall -> IO ()
termSubmitCall stRef (FillRect r c) = do
  let col0 = cast {to=Nat} r.origin.x
      row0 = cast {to=Nat} r.origin.y
      w    = cast {to=Nat} r.size.width
      h    = cast {to=Nat} r.size.height
      tc   = ColorRGB (cast (c.r * 255)) (cast (c.g * 255)) (cast (c.b * 255))
      cell = MkCell ' ' Default tc noStyle
      cols = rtRange col0 (col0 + w)
      rows = rtRange row0 (row0 + h)
  traverse_ (\(co, ro) => drawCell stRef co ro cell) (rtProduct cols rows)

termSubmitCall stRef (DrawText s _ pt c) = do
  let col0 = cast {to=Nat} pt.x
      row0 = cast {to=Nat} pt.y
      tc   = ColorRGB (cast (c.r * 255)) (cast (c.g * 255)) (cast (c.b * 255))
  traverse_ (\(i, ch) => drawCell stRef (col0 + i) row0 (MkCell ch tc Default noStyle))
            (rtZipIdx (unpack s))

termSubmitCall _ _ = pure ()

-- ─── PAL records ─────────────────────────────────────────────────────────────

makeTermRenderer : IORef TermState -> Renderer
makeTermRenderer stRef = MkRenderer
  { beginFrame  = termBeginFrame stRef
  , endFrame    = termEndFrame stRef
  , submitCall  = termSubmitCall stRef
  , loadTexture = \_, _, _ => pure (Left "TUI does not support textures")
  , freeTexture = \(MkTextureHandle _) => pure ()
  , surfaceSize = do
      st <- readIORef stRef
      pure (MkSize (cast st.termSize.cols) (cast st.termSize.rows))
  , pixelRatio  = pure 1.0
  }

makeTermInput : IORef (List Event) -> InputDriver
makeTermInput evtBuf = MkInputDriver
  { pollEvents = do
      evts <- readIORef evtBuf
      writeIORef evtBuf []
      pure evts
  , setCapture      = \_ => pure ()
  , setSoftKeyboard = \_ => pure ()
  }

pumpInput : IORef (List Event) -> IO ()
pumpInput evtBuf = do
  raw <- readStdinNonBlocking
  case raw of
    "" => pure ()
    _  => modifyIORef evtBuf (rawKeyToEvent (parseEscSeq raw) ::)

makeTermWindow : IORef TermState -> WindowDriver
makeTermWindow stRef = MkWindowDriver
  { getSize = do
      st <- readIORef stRef
      pure (MkSize (cast st.termSize.cols) (cast st.termSize.rows))
  , setTitle      = \title => termWrite ("\x1b]0;" ++ title ++ "\x07")
  , requestRedraw = pure ()
  , onResize      = \_ => pure ()
  , onClose       = \_ => pure ()
  }

-- ─── Entry points ────────────────────────────────────────────────────────────

||| Initialise and return the TUI platform bundle.
public export
terminalPlatform : IO Iris.Platform.Interface.Platform
terminalPlatform = do
  sz     <- queryTermSize
  let buf = emptyBuffer sz.cols sz.rows
  stRef  <- newIORef (MkTermState buf buf sz True)
  evtBuf <- newIORef (the (List Event) [])
  enableRawMode
  termWrite termInit
  termFlush
  pure (MkPlatform
    (makeTermRenderer stRef)
    (makeTermInput evtBuf)
    (makeTermWindow stRef))

||| Restore the terminal on exit.
public export
terminalShutdown : IO ()
terminalShutdown = do
  termWrite termTeardown
  termFlush
  disableRawMode
