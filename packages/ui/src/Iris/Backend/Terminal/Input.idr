||| Iris.Backend.Terminal.Input
||| Raw-mode stdin reader and ANSI escape-sequence parser.
|||
||| Converts raw bytes from the terminal into typed Iris Events.
|||
||| In raw mode (VMIN=0 VTIME=1) each read() returns:
|||   • 1 byte  — regular keypress
|||   • 3+ bytes — escape sequence (arrow, F-key, …)
|||   • 0 bytes  — timeout (no input)
module Iris.Backend.Terminal.Input

import Iris.Platform.Event
import Iris.Core.Types

-- ─── Local string helpers ────────────────────────────────────────────────────

charToStr : Char -> String
charToStr c = pack [c]

spanWhile : (Char -> Bool) -> List Char -> (List Char, List Char)
spanWhile _ []        = ([], [])
spanWhile p (x :: xs) =
  if p x then let (ys, zs) = spanWhile p xs in (x :: ys, zs)
         else ([], x :: xs)

listLast : List Char -> Maybe Char
listLast []        = Nothing
listLast (x :: []) = Just x
listLast (_ :: xs) = listLast xs

listButLast : List Char -> List Char
listButLast []        = []
listButLast (_ :: []) = []
listButLast (x :: xs) = x :: listButLast xs

toUpperChar : Char -> Char
toUpperChar c =
  if c >= 'a' && c <= 'z' then chr (ord c - 32) else c

toUpperStr : String -> String
toUpperStr = pack . map toUpperChar . unpack

-- ─── Raw key ─────────────────────────────────────────────────────────────────

public export
data RawKey
  = RKChar      Char         -- printable character
  | RKCtrl      Char         -- Ctrl + character
  | RKAlt       Char         -- Alt  + character
  | RKEscape                 -- bare ESC
  | RKEnter                  -- Enter / Return
  | RKTab                    -- Tab
  | RKBackspace              -- Backspace / DEL
  | RKUp | RKDown | RKLeft | RKRight
  | RKHome | RKEnd | RKPgUp | RKPgDn | RKInsert | RKDelete
  | RKFn        Nat
  | RKMouse     Nat Nat Nat Bool   -- button col row pressed
  | RKResize    Nat Nat            -- cols rows
  | RKPaste     String             -- multi-char non-escape input (paste / rapid typing)
  | RKUnknown   String

-- ─── SGR mouse parser ────────────────────────────────────────────────────────

parseSGRMouse : String -> RawKey
parseSGRMouse s =
  case spanWhile (/= ';') (unpack s) of
    (btnChars, ';' :: rest1) =>
      case spanWhile (/= ';') rest1 of
        (colChars, ';' :: rest2) =>
          let pressed  = listLast rest2 == Just 'M'
              rowChars = listButLast rest2
              btn = cast {to=Nat} (cast {to=Int} (pack btnChars))
              c   = cast {to=Nat} (cast {to=Int} (pack colChars))
              r   = cast {to=Nat} (cast {to=Int} (pack rowChars))
          in RKMouse btn (c `minus` 1) (r `minus` 1) pressed
        _ => RKUnknown s
    _ => RKUnknown s

-- ─── Single-character classifier ─────────────────────────────────────────────

||| Classify a single byte that is NOT part of an escape sequence.
classifyChar : Char -> RawKey
classifyChar c =
  let code = ord c
  in if      c == '\x0d' || c == '\x0a' then RKEnter      -- CR or LF = Enter
     else if c == '\x7f' || c == '\x08' then RKBackspace  -- DEL or BS
     else if c == '\x09'                then RKTab
     else if code == 0                  then RKCtrl ' '   -- Ctrl+Space (NUL)
     else if code > 0 && code < 27      then RKCtrl (chr (code + 64))  -- Ctrl+A..Z
     else if code == 27                 then RKEscape      -- ESC bare
     else                                    RKChar c      -- printable

-- ─── Main escape-sequence parser ─────────────────────────────────────────────

||| Parse a raw stdin string (1–31 bytes) into a single RawKey.
|||
||| For multi-char non-escape input (paste / rapid typing), the first
||| character is classified and the rest are discarded.
||| Full multi-key parsing will be added in a later phase.
public export
parseEscSeq : String -> RawKey
parseEscSeq s =
  case unpack s of
    -- ── Empty ───────────────────────────────────────────────────────────────
    []                                 => RKUnknown ""

    -- ── Escape sequences ────────────────────────────────────────────────────
    '\x1b' :: '[' :: 'A' :: []         => RKUp
    '\x1b' :: '[' :: 'B' :: []         => RKDown
    '\x1b' :: '[' :: 'C' :: []         => RKRight
    '\x1b' :: '[' :: 'D' :: []         => RKLeft
    '\x1b' :: '[' :: 'H' :: []         => RKHome
    '\x1b' :: '[' :: 'F' :: []         => RKEnd
    '\x1b' :: '[' :: 'Z' :: []         => RKTab     -- Shift+Tab
    '\x1b' :: '[' :: '1' :: '~' :: []  => RKHome
    '\x1b' :: '[' :: '2' :: '~' :: []  => RKInsert
    '\x1b' :: '[' :: '3' :: '~' :: []  => RKDelete
    '\x1b' :: '[' :: '4' :: '~' :: []  => RKEnd
    '\x1b' :: '[' :: '5' :: '~' :: []  => RKPgUp
    '\x1b' :: '[' :: '6' :: '~' :: []  => RKPgDn
    '\x1b' :: '[' :: '7' :: '~' :: []  => RKHome
    '\x1b' :: '[' :: '8' :: '~' :: []  => RKEnd
    -- Function keys
    '\x1b' :: 'O' :: 'P' :: []         => RKFn 1
    '\x1b' :: 'O' :: 'Q' :: []         => RKFn 2
    '\x1b' :: 'O' :: 'R' :: []         => RKFn 3
    '\x1b' :: 'O' :: 'S' :: []         => RKFn 4
    -- SGR mouse
    '\x1b' :: '[' :: '<' :: rest        => parseSGRMouse (pack rest)
    -- Alt + single char (must come after all ESC [ ... sequences)
    '\x1b' :: c :: []                  => RKAlt c
    -- Bare ESC (lone 0x1b)
    ['\x1b']                           => RKEscape

    -- ── Single bytes ────────────────────────────────────────────────────────
    [c]                                => classifyChar c

    -- ── Multi-byte non-escape (paste / rapid keys): emit all chars ──────────
    (c :: _)                           => RKPaste s

-- ─── RawKey → Iris Event ────────────────────────────────────────────────────────────

public export
noMods : ModifierKeys
noMods = MkModifiers False False False False

altMods : ModifierKeys
altMods = MkModifiers False False True False

ctrlMods : ModifierKeys
ctrlMods = MkModifiers False True False False

mkKey : String -> Event
mkKey k = KeyboardEvent (MkKeyEvent KeyDown k k noMods Nothing)

||| Convert a RawKey to the unified Iris Event type.
||| The resulting KeyEvent.key is the string your handleKey should match.
public export
rawKeyToEvent : RawKey -> Event

-- Printable chars: key = the character itself, e.g. "a", " ", "1"
rawKeyToEvent (RKChar c) =
  let k = charToStr c
  in KeyboardEvent (MkKeyEvent KeyDown k ("Key" ++ toUpperStr k) noMods (Just c))

-- Control chars: key = "Ctrl+a" etc.
rawKeyToEvent (RKCtrl c) =
  let k = "Ctrl+" ++ charToStr c
  in KeyboardEvent (MkKeyEvent KeyDown k "" ctrlMods Nothing)

-- Alt chars: key = "Alt+a" etc.
rawKeyToEvent (RKAlt c) =
  let k = "Alt+" ++ charToStr c
  in KeyboardEvent (MkKeyEvent KeyDown k "" altMods (Just c))

rawKeyToEvent RKEscape    = mkKey "Escape"
rawKeyToEvent RKEnter     = KeyboardEvent (MkKeyEvent KeyDown "Enter" "Enter" noMods (Just '\n'))
rawKeyToEvent RKTab       = KeyboardEvent (MkKeyEvent KeyDown "Tab"   "Tab"   noMods (Just '\t'))
rawKeyToEvent RKBackspace = mkKey "Backspace"
rawKeyToEvent RKUp        = mkKey "ArrowUp"
rawKeyToEvent RKDown      = mkKey "ArrowDown"
rawKeyToEvent RKLeft      = mkKey "ArrowLeft"
rawKeyToEvent RKRight     = mkKey "ArrowRight"
rawKeyToEvent RKHome      = mkKey "Home"
rawKeyToEvent RKEnd       = mkKey "End"
rawKeyToEvent RKPgUp      = mkKey "PageUp"
rawKeyToEvent RKPgDn      = mkKey "PageDown"
rawKeyToEvent RKInsert    = mkKey "Insert"
rawKeyToEvent RKDelete    = mkKey "Delete"
rawKeyToEvent (RKFn n)    = mkKey ("F" ++ show n)

rawKeyToEvent (RKMouse btn c r pressed) =
  let action = if pressed then PointerDown else PointerUp
      button = case btn of
                 0 => Just PrimaryBtn
                 1 => Just MiddleBtn
                 2 => Just SecondaryBtn
                 _ => Nothing
  in PointerEvt (MkPointerEvent action Mouse 0
       (MkPoint (cast c) (cast r)) (MkPoint 0 0) button 1.0 noMods)

rawKeyToEvent (RKResize c r) =
  WindowEvt (WindowResized (MkSize (cast c) (cast r)))

rawKeyToEvent (RKPaste s)  = TextInput s

rawKeyToEvent (RKUnknown _) = Custom "unknown-key"
