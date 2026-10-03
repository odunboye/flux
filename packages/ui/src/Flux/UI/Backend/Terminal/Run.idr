||| Flux.UI.Backend.Terminal.Run
||| Platform entry point: runs an abstract Flux UI App in the terminal.
|||
||| Use this from your terminal Main.idr:
|||
|||   main : IO ()
|||   main = runTUI myApp
|||
||| The same `myApp` value can be passed to
|||   Flux.UI.Backend.Web.DOM.Run.runWeb   (browser)
||| without changing any application code.
module Flux.UI.Backend.Terminal.Run

import Data.IORef
import System.Concurrency
import System.Future
import Flux.UI.State.TEA
import Flux.UI.Platform.Event
import Flux.UI.App as UIApp
import Flux.UI.Widget
import Flux.UI.Runtime.Common as Common
import Flux.UI.Backend.Terminal.ANSI
import Flux.UI.Backend.Terminal.Input
import Flux.UI.Backend.Terminal.FFI
import Flux.UI.Backend.Terminal.WidgetRender

-- ─── Command executor ────────────────────────────────────────────────────────

-- Cooperative starters run on the owner loop so cleanup registration cannot
-- race with shutdown. They must return promptly after starting asynchronous IO.
-- Raw Task/StreamTask retain their asynchronous execution but cannot be killed.
export covering
execCmd : Cmd outMsg -> (outMsg -> IO ()) -> RuntimeControl -> IO ()
execCmd command send control = do
  stopped <- readIORef control.quit
  when (not stopped) $ case command of
    None => pure ()
    Batch commands => traverse_ (\next => execCmd next send control) commands
    MapCmd f nested => execCmd nested (send . f) control
    Task action => ignore $ forkIO $ do
      stopped <- readIORef control.quit
      unless stopped (action >>= deliver)
    StreamTask action => ignore $ forkIO $ do
      stopped <- readIORef control.quit
      unless stopped (action deliver)
    CancellableTask start => Common.execCmdManaged (CancellableTask start) send control
    QuitApp => Common.execCmdManaged QuitApp send control
  where
    deliver : outMsg -> IO ()
    deliver message = do
      stopped <- readIORef control.quit
      unless stopped (send message)

-- Messages always enter the owner loop through its channel. A callback racing
-- quit may enqueue, but cannot apply an update after shutdown.
covering
dispatch : UIApp mdl outMsg -> IORef mdl -> RuntimeControl -> Channel outMsg -> outMsg -> IO ()
dispatch app modelRef control chan msg = do
  stopped <- readIORef control.quit
  unless stopped $ do
    m <- readIORef modelRef
    let (m', cmd) = app.update msg m
    writeIORef modelRef m'
    execCmd cmd (channelPut chan) control

covering
drainChannel : UIApp mdl outMsg -> IORef mdl -> RuntimeControl -> Channel outMsg -> IO ()
drainChannel app modelRef control chan = do
  stopped <- readIORef control.quit
  unless stopped $ do
    result <- channelGetNonBlocking chan
    case result of
      Nothing => pure ()
      Just msg => do
        dispatch app modelRef control chan msg
        drainChannel app modelRef control chan

-- ─── Ctrl+C detection ────────────────────────────────────────────────────────

isCtrlC : String -> Bool
isCtrlC s = case unpack s of ['\x03'] => True; _ => False

-- ─── Main loop ───────────────────────────────────────────────────────────────

covering
loop : UIApp mdl outMsg -> IORef mdl -> RuntimeControl -> IORef Int -> Channel outMsg -> IO ()
loop app modelRef control frameRef chan = do
  -- drain async results first
  drainChannel app modelRef control chan

  quit <- readIORef control.quit
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
        Just tm => dispatch app modelRef control chan tm

    -- pace
    sleepMs 16

    -- input
    raw <- termRead
    when (isCtrlC raw) (Common.execCmdManaged QuitApp (channelPut chan) control)
    quit2 <- readIORef control.quit
    when (not quit2) $ do
      when (raw /= "") $ do
        let evt = rawKeyToEvent (parseEscSeq raw)
        case evt of
          KeyboardEvent ke => do
            m <- readIORef modelRef
            case app.handleEvent m (KeyboardEvent ke) of
              Nothing  => pure ()
              Just msg => dispatch app modelRef control chan msg
          _ => pure ()
      loop app modelRef control frameRef chan

-- ─── runTUI ──────────────────────────────────────────────────────────────────

||| Run a Flux UI App in the terminal.
public export
covering
runTUI : UIApp mdl outMsg -> IO ()
runTUI app = do
  let (initMdl, initCmd) = app.init
  modelRef <- newIORef initMdl
  quitRef  <- newIORef False
  control  <- newRuntimeControl quitRef
  chan     <- makeChannel {a = outMsg}
  frameRef <- newIORef (the Int 0)

  -- startup commands (results arrive on channel)
  execCmd initCmd (channelPut chan) control

  -- enter TUI
  rawModeOn
  termWrite termInit

  loop app modelRef control frameRef chan

  -- Retire any remaining cooperative work before restoring the terminal.
  writeIORef control.quit True
  cancelActiveEffects control

  -- exit TUI
  termWrite termTeardown
  rawModeOff
  putStrLn "\nBye!"
