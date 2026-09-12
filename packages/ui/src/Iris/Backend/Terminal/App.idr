||| Iris.Backend.Terminal.App
||| TUIApp record and runTUI — the real TUI runtime loop.
|||
||| Async design:
|||   Task and StreamTask are forked onto background threads via forkIO.
|||   Results flow back through a Channel msg that the main loop drains
|||   non-blocking each frame.  QuitApp executes synchronously.
|||   MapCmd properly threads the transform through the send callback.
module Iris.Backend.Terminal.App

import Data.IORef
import System.Concurrency
import System.Future
import Iris.State.TEA
import Iris.Platform.Event
import Iris.Backend.Terminal.Types
import Iris.Backend.Terminal.ANSI
import Iris.Backend.Terminal.Input
import Iris.Backend.Terminal.Renderer
import Iris.Backend.Terminal.FFI
import Iris.Widget.TUI.Core

-- ─── TUIApp ──────────────────────────────────────────────────────────────────

public export
record TUIApp (model : Type) (msg : Type) where
  constructor MkTUIApp
  init      : (model, Cmd msg)
  update    : msg -> model -> (model, Cmd msg)
  view      : model -> TUIWidget msg
  handleKey : model -> KeyEvent -> Maybe msg
  ||| If set, dispatch this message every ~100 ms for animations.
  tickMsg   : Maybe msg

-- ─── Command executor ────────────────────────────────────────────────────────

-- `send` delivers a result msg into the async channel.
covering
execCmd : Cmd msg -> (msg -> IO ()) -> IORef Bool -> IO ()
execCmd None          _    _       = pure ()
execCmd (Batch cs)    send quitRef = traverse_ (\c => execCmd c send quitRef) cs
execCmd (MapCmd f c)  send quitRef = execCmd c (send . f) quitRef
execCmd (Task io)     send _       = ignore $ forkIO (io >>= send)
execCmd (StreamTask act) send _   = ignore $ forkIO (act send)
execCmd (CancellableTask act) send _ = ignore $ forkIO (ignore (act send))
execCmd QuitApp       _    quitRef = writeIORef quitRef True

-- ─── Ctrl+C detection ────────────────────────────────────────────────────────

isCtrlC : String -> Bool
isCtrlC s = case unpack s of
  ['\x03'] => True
  _        => False

-- ─── Message dispatcher ──────────────────────────────────────────────────────

covering
dispatchMsg : TUIApp mdl outMsg
            -> IORef mdl
            -> IORef Bool
            -> Channel outMsg
            -> outMsg
            -> IO ()
dispatchMsg app modelRef quitRef chan theMsg = do
  m <- readIORef modelRef
  let (newModel, cmd) = app.update theMsg m
  writeIORef modelRef newModel
  execCmd cmd (channelPut chan) quitRef

-- ─── Channel drain (non-blocking) ────────────────────────────────────────────

-- Drain all pending messages from the channel without blocking.
covering
drainChannel : TUIApp mdl outMsg
             -> IORef mdl
             -> IORef Bool
             -> Channel outMsg
             -> IO ()
drainChannel app modelRef quitRef chan = do
  result <- channelGetNonBlocking chan
  case result of
    Nothing  => pure ()
    Just msg => do
      dispatchMsg app modelRef quitRef chan msg
      drainChannel app modelRef quitRef chan

-- ─── Paste dispatch ──────────────────────────────────────────────────────────

-- Dispatch each character in a paste string as an individual KeyDown event.
covering
dispatchPaste : TUIApp mdl outMsg -> IORef mdl -> IORef Bool -> Channel outMsg -> String -> IO ()
dispatchPaste app modelRef quitRef chan s =
  traverse_ dispatchChar (unpack s)
  where
    covering
    dispatchChar : Char -> IO ()
    dispatchChar c = do
      m <- readIORef modelRef
      let ke = MkKeyEvent KeyDown (pack [c]) ("Key" ++ pack [c]) noMods (Just c)
      case app.handleKey m ke of
        Nothing  => pure ()
        Just msg => dispatchMsg app modelRef quitRef chan msg

-- ─── Main loop ───────────────────────────────────────────────────────────────

covering
loop : TUIApp mdl outMsg
     -> IORef mdl
     -> IORef Bool
     -> IORef Int         -- frame counter for tick pacing
     -> Channel outMsg
     -> IO ()
loop app modelRef quitRef frameRef chan = do
  -- drain async results first
  drainChannel app modelRef quitRef chan

  quit <- readIORef quitRef
  when (not quit) $ do
    -- render current state
    mdl <- readIORef modelRef
    termWrite (renderFrame (app.view mdl))

    -- advance frame; dispatch tickMsg every 6 frames (~100 ms at 60fps)
    n <- readIORef frameRef
    let n' = n + 1
    writeIORef frameRef n'
    when (n' `mod` 6 == 0) $
      case app.tickMsg of
        Nothing => pure ()
        Just tm => dispatchMsg app modelRef quitRef chan tm

    -- pace at ~60fps
    sleepMs 16

    -- read stdin
    raw <- termRead
    when (isCtrlC raw) (writeIORef quitRef True)
    quit2 <- readIORef quitRef
    when (not quit2) $ do
      when (raw /= "") $ do
        let ke  = parseEscSeq raw
            evt = rawKeyToEvent ke
        case evt of
          KeyboardEvent keyEvt => do
            m <- readIORef modelRef
            case app.handleKey m keyEvt of
              Nothing      => pure ()
              Just theMsg  => dispatchMsg app modelRef quitRef chan theMsg
          TextInput text => dispatchPaste app modelRef quitRef chan text
          _ => pure ()
      loop app modelRef quitRef frameRef chan

-- ─── runTUI ──────────────────────────────────────────────────────────────────

||| Run an Iris App in the terminal.
public export
covering
runTUI : TUIApp mdl outMsg -> IO ()
runTUI app = do
  let (initMdl, initCmd) = app.init
  modelRef <- newIORef initMdl
  quitRef  <- newIORef False
  chan     <- makeChannel {a = outMsg}

  -- fire startup commands (results will arrive on channel)
  execCmd initCmd (channelPut chan) quitRef

  -- enter TUI mode
  rawModeOn
  termWrite termInit

  -- main loop
  frameRef <- newIORef (the Int 0)
  loop app modelRef quitRef frameRef chan

  -- restore terminal
  termWrite termTeardown
  rawModeOff
  putStrLn "\nBye!"
