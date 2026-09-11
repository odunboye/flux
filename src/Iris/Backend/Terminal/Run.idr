||| Iris.Backend.Terminal.Run
||| Platform entry point: runs an abstract Iris App in the terminal.
|||
||| Use this from your terminal Main.idr:
|||
|||   main : IO ()
|||   main = runTUI myApp
|||
||| The same `myApp` value can be passed to
|||   Iris.Backend.Web.DOM.Run.runWeb   (browser)
||| without changing any application code.
module Iris.Backend.Terminal.Run

import Data.IORef
import System.Concurrency
import System.Future
import Iris.State.TEA
import Iris.Platform.Event
import Iris.App as IrisApp
import Iris.Widget
import Iris.Backend.Terminal.ANSI
import Iris.Backend.Terminal.Input
import Iris.Backend.Terminal.FFI
import Iris.Backend.Terminal.WidgetRender

-- ─── Command executor ────────────────────────────────────────────────────────

covering
execCmd : Cmd outMsg -> (outMsg -> IO ()) -> IORef Bool -> IO ()
execCmd None             _    _       = pure ()
execCmd (Batch cs)       send quitRef = traverse_ (\c => execCmd c send quitRef) cs
execCmd (MapCmd f c)     send quitRef = execCmd c (send . f) quitRef
execCmd (Task io)        send _       = ignore $ forkIO (io >>= send)
execCmd (StreamTask act) send _       = ignore $ forkIO (act send)
execCmd QuitApp          _    quitRef = writeIORef quitRef True

-- ─── Message dispatcher ──────────────────────────────────────────────────────

covering
dispatch : IrisApp mdl outMsg -> IORef mdl -> IORef Bool -> Channel outMsg -> outMsg -> IO ()
dispatch app modelRef quitRef chan msg = do
  m <- readIORef modelRef
  let (m', cmd) = app.update msg m
  writeIORef modelRef m'
  execCmd cmd (channelPut chan) quitRef

-- ─── Channel drain ───────────────────────────────────────────────────────────

covering
drainChannel : IrisApp mdl outMsg -> IORef mdl -> IORef Bool -> Channel outMsg -> IO ()
drainChannel app modelRef quitRef chan = do
  result <- channelGetNonBlocking chan
  case result of
    Nothing  => pure ()
    Just msg => do
      dispatch app modelRef quitRef chan msg
      drainChannel app modelRef quitRef chan

-- ─── Ctrl+C detection ────────────────────────────────────────────────────────

isCtrlC : String -> Bool
isCtrlC s = case unpack s of ['\x03'] => True; _ => False

-- ─── Main loop ───────────────────────────────────────────────────────────────

covering
loop : IrisApp mdl outMsg -> IORef mdl -> IORef Bool -> IORef Int -> Channel outMsg -> IO ()
loop app modelRef quitRef frameRef chan = do
  -- drain async results first
  drainChannel app modelRef quitRef chan

  quit <- readIORef quitRef
  when (not quit) $ do
    -- render
    mdl <- readIORef modelRef
    cols <- termCols
    rows <- termRows
    termWrite (renderScreen (app.view mdl) (cast cols) (cast rows))

    -- animation tick every 6 frames (~100 ms at 60 fps)
    n <- readIORef frameRef
    let n' = n + 1
    writeIORef frameRef n'
    when (n' `mod` 6 == 0) $
      case app.tickMsg of
        Nothing => pure ()
        Just tm => dispatch app modelRef quitRef chan tm

    -- pace
    sleepMs 16

    -- input
    raw <- termRead
    when (isCtrlC raw) (writeIORef quitRef True)
    quit2 <- readIORef quitRef
    when (not quit2) $ do
      when (raw /= "") $ do
        let evt = rawKeyToEvent (parseEscSeq raw)
        case evt of
          KeyboardEvent ke => do
            m <- readIORef modelRef
            case app.handleEvent m (KeyboardEvent ke) of
              Nothing  => pure ()
              Just msg => dispatch app modelRef quitRef chan msg
          _ => pure ()
      loop app modelRef quitRef frameRef chan

-- ─── runTUI ──────────────────────────────────────────────────────────────────

||| Run an Iris App in the terminal.
public export
covering
runTUI : IrisApp mdl outMsg -> IO ()
runTUI app = do
  let (initMdl, initCmd) = app.init
  modelRef <- newIORef initMdl
  quitRef  <- newIORef False
  chan     <- makeChannel {a = outMsg}
  frameRef <- newIORef (the Int 0)

  -- startup commands (results arrive on channel)
  execCmd initCmd (channelPut chan) quitRef

  -- enter TUI
  rawModeOn
  termWrite termInit

  loop app modelRef quitRef frameRef chan

  -- exit TUI
  termWrite termTeardown
  rawModeOff
  putStrLn "\nBye!"
