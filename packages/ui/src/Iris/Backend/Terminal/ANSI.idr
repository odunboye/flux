||| Iris.Backend.Terminal.ANSI
||| ANSI / VT100 escape sequence generator.
|||
||| All functions here return pure Strings — the renderer feeds them
||| to stdout via a single buffered write per frame.
|||
||| Reference: https://en.wikipedia.org/wiki/ANSI_escape_code
module Iris.Backend.Terminal.ANSI

import Iris.Backend.Terminal.Types

-- ─── ESC character ──────────────────────────────────────────────────────────

||| The ASCII ESC character (0x1B).
esc : String
esc = "\x1b"

||| Control Sequence Introducer: ESC [
csi : String
csi = "\x1b["

-- ─── Screen / cursor control ────────────────────────────────────────────────

||| Clear the entire screen.
public export
clearScreen : String
clearScreen = csi ++ "2J"

||| Move cursor to home position (1,1).
public export
cursorHome : String
cursorHome = csi ++ "H"

||| Move cursor to (col, row) — ANSI is 1-indexed, col/row are 0-indexed here.
public export
moveCursor : Nat -> Nat -> String
moveCursor col row = csi ++ show (row + 1) ++ ";" ++ show (col + 1) ++ "H"

||| Hide the terminal cursor.
public export
hideCursor : String
hideCursor = csi ++ "?25l"

||| Show the terminal cursor.
public export
showCursor : String
showCursor = csi ++ "?25h"

||| Switch to the alternate screen buffer (saves main screen content).
public export
enterAltScreen : String
enterAltScreen = csi ++ "?1049h"

||| Return to the normal screen buffer.
public export
exitAltScreen : String
exitAltScreen = csi ++ "?1049l"

||| Enable SGR mouse tracking (button + motion events).
public export
enableMouse : String
enableMouse = csi ++ "?1000h" ++ csi ++ "?1002h" ++ csi ++ "?1006h"

||| Disable mouse tracking.
public export
disableMouse : String
disableMouse = csi ++ "?1006l" ++ csi ++ "?1002l" ++ csi ++ "?1000l"

-- ─── Graphic rendition (SGR) ────────────────────────────────────────────────

||| Reset all SGR attributes.
public export
resetAttrs : String
resetAttrs = csi ++ "0m"

||| Wrap a list of SGR parameter codes in a single escape sequence.
sgrCodes : List Nat -> String
sgrCodes []     = resetAttrs
sgrCodes (x::xs) = csi ++ intercalate ";" (map show (x::xs)) ++ "m"
  where
    intercalate : String -> List String -> String
    intercalate _   []       = ""
    intercalate _   (s::[])  = s
    intercalate sep (s::ss)  = s ++ sep ++ intercalate sep ss

-- ─── Colour codes ───────────────────────────────────────────────────────────

fgCode16 : Nat -> Nat
fgCode16 n = if n < 8 then 30 + n else 90 + (n `minus` 8)

bgCode16 : Nat -> Nat
bgCode16 n = if n < 8 then 40 + n else 100 + (n `minus` 8)

||| Foreground colour escape sequence.
public export
fgColor : TermColor -> String
fgColor Default            = sgrCodes [39]
fgColor (Color16  n)       = sgrCodes [fgCode16 n]
fgColor (Color256 n)       = sgrCodes [38, 5, n]
fgColor (ColorRGB r g b)   =
  sgrCodes [38, 2, cast r, cast g, cast b]

||| Background colour escape sequence.
public export
bgColor : TermColor -> String
bgColor Default            = sgrCodes [49]
bgColor (Color16  n)       = sgrCodes [bgCode16 n]
bgColor (Color256 n)       = sgrCodes [48, 5, n]
bgColor (ColorRGB r g b)   =
  sgrCodes [48, 2, cast r, cast g, cast b]

-- ─── Style codes ────────────────────────────────────────────────────────────

||| Build an SGR sequence from a CellStyle.
public export
styleCode : CellStyle -> String
styleCode s =
  let codes = catMaybes
        [ if s.bold          then Just 1  else Nothing
        , if s.dim           then Just 2  else Nothing
        , if s.italic        then Just 3  else Nothing
        , if s.underline     then Just 4  else Nothing
        , if s.blink         then Just 5  else Nothing
        , if s.reversed      then Just 7  else Nothing
        , if s.strikethrough then Just 9  else Nothing
        ]
  in if null codes then "" else sgrCodes codes
  where
    catMaybes : List (Maybe a) -> List a
    catMaybes []              = []
    catMaybes (Nothing :: xs) = catMaybes xs
    catMaybes (Just x  :: xs) = x :: catMaybes xs

-- ─── Cell rendering ─────────────────────────────────────────────────────────

||| Render a single cell at the given position to an ANSI string.
||| Includes: move cursor, set colours + style, emit character.
public export
renderCell : Nat -> Nat -> Cell -> String
renderCell col row cell =
  moveCursor col row
    ++ resetAttrs
    ++ fgColor cell.fg
    ++ bgColor cell.bg
    ++ styleCode cell.style
    ++ pack [cell.char]

-- ─── Frame init / teardown ──────────────────────────────────────────────────

||| The escape sequence emitted once at startup.
public export
termInit : String
termInit = enterAltScreen ++ hideCursor ++ enableMouse ++ clearScreen

||| The escape sequence emitted on clean exit.
public export
termTeardown : String
termTeardown = resetAttrs ++ disableMouse ++ showCursor ++ exitAltScreen
