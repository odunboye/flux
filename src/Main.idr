||| Iris coding-agent demo
||| Streams responses from the Anthropic API in a TUI chat interface.
||| Set ANTHROPIC_API_KEY before running.
module Main

import System
import Data.Maybe
import Iris.State.TEA
import Iris.Platform.Event
import Iris.Backend.Terminal.Types
import Iris.Backend.Terminal.App
import Iris.Widget.TUI.Core
import Iris.Widget.TUI.Primitives
import Iris.Widget.TUI.Progress
import Iris.Widget.TUI.Input
import Iris.Widget.TUI.Scroll
import Iris.Effect.Http

-- ─── Model / Msg ─────────────────────────────────────────────────────────────

data AgentStatus = Idle | Streaming

data Msg
  = KeyEvt    KeyEvent
  | Tick
  | Resized   Nat Nat
  | GotToken  String
  | DoneStream
  | StreamErr String
  | NoOp

record Model where
  constructor MkModel
  cols     : Nat
  rows     : Nat
  apiKey   : String
  history  : List (String, String)   -- completed (role, content) for API context
  pending  : String                  -- accumulating streamed response
  inp      : InputState
  chat     : ScrollState
  status   : AgentStatus
  spinTick : Nat

-- ─── Helpers ─────────────────────────────────────────────────────────────────

-- Escape special chars for JSON string value
jsonEsc : String -> String
jsonEsc s = pack (go (unpack s))
  where
    go : List Char -> List Char
    go []           = []
    go ('"'  :: cs) = '\\' :: '"'  :: go cs
    go ('\n' :: cs) = '\\' :: 'n'  :: go cs
    go ('\r' :: cs) = '\\' :: 'r'  :: go cs
    go ('\\' :: cs) = '\\' :: '\\' :: go cs
    go (c    :: cs) = c :: go cs

-- Extract the value of the first "text" key from a JSON fragment.
-- Used to parse Anthropic SSE content_block_delta chunks.
extractText : String -> String
extractText s = pack (getVal (findKey (unpack s)))
  where
    findKey : List Char -> List Char
    findKey [] = []
    findKey ('"'::'t'::'e'::'x'::'t'::'"'::':'::'\"'::rest) = rest
    findKey (_ :: cs) = findKey cs

    getVal : List Char -> List Char
    getVal [] = []
    getVal ('"' :: _) = []
    getVal ('\\' :: '"'  :: cs) = '"'  :: getVal cs
    getVal ('\\' :: 'n'  :: cs) = '\n' :: getVal cs
    getVal ('\\' :: 'r'  :: cs) = '\r' :: getVal cs
    getVal ('\\' :: '\\' :: cs) = '\\' :: getVal cs
    getVal (c :: cs) = c :: getVal cs

-- Build Anthropic messages array
msgList : List (String, String) -> String
msgList msgs = "[" ++ go msgs ++ "]"
  where
    mkMsg : (String, String) -> String
    mkMsg (r, c) =
      "{\"role\":\"" ++ r ++ "\",\"content\":\"" ++ jsonEsc c ++ "\"}"

    go : List (String, String) -> String
    go []        = ""
    go (x :: []) = mkMsg x
    go (x :: xs) = mkMsg x ++ "," ++ go xs

-- Build the full Anthropic request body
buildBody : List (String, String) -> String
buildBody msgs =
  "{\"model\":\"claude-3-5-sonnet-20241022\"" ++
  ",\"max_tokens\":1024" ++
  ",\"stream\":true" ++
  ",\"messages\":" ++ msgList msgs ++ "}"

-- ─── API call ────────────────────────────────────────────────────────────────

covering
streamAPI : String -> List (String, String) -> Cmd Msg
streamAPI apiKey msgs =
  stream
    (MkRequest POST "https://api.anthropic.com/v1/messages"
      [ ("x-api-key",          apiKey)
      , ("anthropic-version",  "2023-06-01")
      , ("content-type",       "application/json")
      ]
      (Just (buildBody msgs)))
    (\case
       Chunk raw =>
         let t = extractText raw
         in if t == "" then NoOp else GotToken t
       Done           => DoneStream
       StreamError e  => StreamErr e)

-- ─── Update ──────────────────────────────────────────────────────────────────

covering
update : Msg -> Model -> (Model, Cmd Msg)

update (Resized c r) m = ({ cols := c, rows := r } m, none)

update Tick m = ({ spinTick $= (+ 1) } m, none)

update NoOp m = (m, none)

update (GotToken t) m =
  ( { pending $= (++ t), chat $= appendText t } m, none )

update DoneStream m =
  let asst    = ("assistant", m.pending)
      m'      = { history  $= (++ [asst])
                , pending  := ""
                , status   := Idle
                , chat     $= appendLine ""
                } m
  in (m', none)

update (StreamErr e) m =
  let m' = { history  $= (++ [("error", e)])
           , pending  := ""
           , status   := Idle
           , chat     $= (appendLine ("[error] " ++ e) . appendLine "")
           } m
  in (m', none)

update (KeyEvt ke) m =
  case ke.key of
    "q"         => if isIdle m then (m, quit) else (m, none)
    "Ctrl+C"    => (m, quit)
    "Enter"     => submit m
    "Backspace" => ({ inp $= deleteBack }           m, none)
    "Delete"    => ({ inp $= deleteForward }         m, none)
    "ArrowLeft" => ({ inp $= cursorLeft }            m, none)
    "ArrowRight"=> ({ inp $= cursorRight }           m, none)
    "Home"      => ({ inp $= cursorToHome }          m, none)
    "End"       => ({ inp $= cursorToEnd }           m, none)
    "ArrowUp"   => ({ chat $= scrollUp 3 }           m, none)
    "ArrowDown" => ({ chat $= scrollDown 3 }         m, none)
    "PageUp"    => ({ chat $= scrollUp 10 }          m, none)
    "PageDown"  => ({ chat $= scrollDown 10 }        m, none)
    _           => case ke.char of
                     Just c  => ({ inp $= insertChar c } m, none)
                     Nothing => (m, none)
  where
    isIdle : Model -> Bool
    isIdle mm = case mm.status of Idle => True; _ => False

    submit : Model -> (Model, Cmd Msg)
    submit mm =
      let query = mm.inp.value
      in if query == "" then (mm, none)
         else
           let newHist = mm.history ++ [("user", query)]
               m'      = { history := newHist
                         , inp     := initInput
                         , status  := Streaming
                         , chat    $= (scrollToEnd . appendLine "[you] " . appendText query . appendLine "" . appendLine "[agent] ")
                         } mm
           in (m', streamAPI mm.apiKey newHist)

-- ─── View ────────────────────────────────────────────────────────────────────

view : Model -> TUIWidget Msg
view m =
  let w       = m.cols
      h       = m.rows
      chatH   = if h > 7 then h `minus` 7 else 1
      inputTop= h `minus` 5
      helpTop = h `minus` 1

      -- Header
      hdrProps = withBorder thinBorder (withBg (Color16 4) (withFg (Color16 15)
                   (sized w 2 (at 0 0 defaultTUI))))
      hdr      = TBox hdrProps
                   [ TText (withBold (withFg (Color16 15) (at 2 0 defaultTUI)))
                       " iris coding agent  |  Tab: focus  q: quit  arrows: scroll"
                   ]

      -- Chat scroll pane
      chatProps = withBorder thinBorder
                    (sized w (chatH + 2) (at 0 2 defaultTUI))
      chatCfg   = { contentFg     := Color16 7
                  , showScrollbar := True
                  , scrollbarFg   := Color16 8
                  } (defaultScrollConfig chatProps)
      chatPane  = tuiScroll chatCfg m.chat

      -- Input field
      inpProps  = sized (w `minus` 2) 1 (at 1 (inputTop + 1) defaultTUI)
      inpCfg    = { focusedFg     := Color16 15
                  , focusedBg     := Color16 0
                  , blurredFg     := Color16 7
                  , placeholder   := "Ask anything…  (Enter to send)"
                  } (defaultInputConfig inpProps)
      inpFocused= { focused := True } m.inp
      inpBox    = TBox (withBorder thinBorder (sized w 3 (at 0 inputTop defaultTUI)))
                    [ tuiInput inpCfg inpFocused ]

      -- Status / spinner line
      statusStr = case m.status of
        Idle      => " ready  |  " ++ show (cast {to=Int} (length m.history) `div` 2) ++ " exchange(s)"
        Streaming => ""
      statusTxt = TText (withFg (Color16 8) (at 1 helpTop defaultTUI)) statusStr

      spinWidget = case m.status of
        Streaming =>
          let spCfg = { label := Just "  thinking…" } (defaultSpinnerConfig (at 1 helpTop defaultTUI))
          in tuiSpinner spCfg m.spinTick
        Idle => tuiSpacer

  in TVBox (sized w h (at 0 0 defaultTUI))
       [ hdr
       , chatPane
       , inpBox
       , statusTxt
       , spinWidget
       ]

-- ─── App ─────────────────────────────────────────────────────────────────────

covering
main : IO ()
main = do
  mKey <- getEnv "ANTHROPIC_API_KEY"
  let apiKey = fromMaybe "" mKey
  let welcome =
        if apiKey == ""
          then [ "[warn] ANTHROPIC_API_KEY not set — responses will fail"
               , "[hint] export ANTHROPIC_API_KEY=sk-ant-..."
               , ""
               ]
          else [ "[ready] Connected to claude-3-5-sonnet-20241022"
               , "[hint]  Type a message and press Enter to chat"
               , ""
               ]
  let initChat = foldl (\s, l => appendLine l s) initScroll welcome
  let initModel = MkModel 80 24 apiKey [] "" initInput initChat Idle 0
  let app = MkTUIApp
        { init         = (initModel, none)
        , update       = update
        , view         = view
        , handleKey    = \m, ke => Just (KeyEvt ke)
        , tickMsg      = Just Tick
        }
  runTUI app
