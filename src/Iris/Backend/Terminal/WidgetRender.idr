||| Iris.Backend.Terminal.WidgetRender
||| Two-pass layout + ANSI renderer for abstract Widget trees.
module Iris.Backend.Terminal.WidgetRender

import Iris.Widget
import Iris.Backend.Terminal.ANSI
import Iris.Backend.Terminal.Types

-- ─── Layout types ────────────────────────────────────────────────────────────

public export
record WSize where
  constructor MkWSize
  w : Nat
  h : Nat

public export
record WRect where
  constructor MkWRect
  col : Nat
  row : Nat
  w   : Nat
  h   : Nat

-- ─── Untrusted-text sanitization ─────────────────────────────────────────────

||| Strips ASCII C0 (0x00-0x1F, 0x7F) and C1 (0x80-0x9F) control
||| characters out of widget-supplied text before it's spliced into
||| ANSI output. Every `WText`/`WInput`/`WButton` string and every
||| border title ultimately comes from application/model data - an API
||| response, a user-entered field, an externally supplied name - none
||| of it under this renderer's own control the way `moveCursor`/
||| `styleAttrs`/`resetAttrs` (this module's own generated sequences)
||| are. Without this, a value containing a real ESC (0x1B) - the byte
||| that begins every ANSI/CSI/OSC sequence - could reposition the
||| cursor, change colors mid-render, or on some terminals trigger an
||| OSC side effect (window title, clipboard write) - a real escape
||| INJECTION, not just garbled output. Mirrors
||| `Iris.Backend.Web.DOM.Render.escapeHTML`'s role for the DOM backend:
||| the one place untrusted text is guaranteed to become inert before
||| it reaches the renderer's own control-sequence vocabulary.
export
sanitizeText : String -> String
sanitizeText = pack . filter isSafe . unpack
  where
    isSafe : Char -> Bool
    isSafe c =
      let code = ord c
      in not ((code >= 0 && code < 32) || code == 127 || (code >= 128 && code < 160))

-- ─── Safe helpers ────────────────────────────────────────────────────────────

natDiv : Nat -> Nat -> Nat
natDiv _  Z = 0
natDiv a  b = cast {to=Nat} (cast {to=Int} a `div` cast {to=Int} b)

sub : Nat -> Nat -> Nat
sub a b = a `minus` b

fromMaybeN : Nat -> Maybe Nat -> Nat
fromMaybeN def Nothing  = def
fromMaybeN _   (Just n) = n

-- ─── Colour mapping ──────────────────────────────────────────────────────────

irisToTerm : IrisColor -> TermColor
irisToTerm Inherit       = Default
irisToTerm (IRGB r g b)  = ColorRGB (cast r) (cast g) (cast b)
irisToTerm IBlue         = Color16  4
irisToTerm IRed          = Color16  1
irisToTerm IGreen        = Color16  2
irisToTerm IYellow       = Color16  3
irisToTerm ICyan         = Color16  6
irisToTerm IMagenta      = Color16  5
irisToTerm IWhite        = Color16 15
irisToTerm IBlack        = Color16  0
irisToTerm IGray         = Color16  8
irisToTerm ILightBlue    = Color16 12
irisToTerm ILightGreen   = Color16 10
irisToTerm ILightRed     = Color16  9
irisToTerm ILightYellow  = Color16 11
irisToTerm IDarkBlue     = Color16  4
irisToTerm IDarkGray     = Color16  8

-- ─── Style → ANSI attrs ──────────────────────────────────────────────────────

styleAttrs : Style -> String
styleAttrs s =
  let fgS = case s.fg of Nothing => fgColor Default; Just c => fgColor (irisToTerm c)
      bgS = case s.bg of Nothing => bgColor Default; Just c => bgColor (irisToTerm c)
      bldS = if s.bold      then "\x1b[1m" else ""
      itlS = if s.italic    then "\x1b[3m" else ""
      ulS  = if s.underline then "\x1b[4m" else ""
  in resetAttrs ++ fgS ++ bgS ++ bldS ++ itlS ++ ulS

-- ─── Border helpers ──────────────────────────────────────────────────────────

borderInset : BorderKind -> Nat
borderInset NoBorder = 0
borderInset _        = 1

hInset : Style -> Nat
hInset s = 2 * (borderInset s.border) + 2 * s.padH

vInset : Style -> Nat
vInset s = 2 * (borderInset s.border) + 2 * s.padV

public export
innerRect : Style -> WRect -> WRect
innerRect s r =
  let bi = borderInset s.border
      lOff = bi + s.padH
      tOff = bi + s.padV
  in MkWRect (r.col + lOff) (r.row + tOff)
             (max 1 (sub r.w (2 * lOff)))
             (max 1 (sub r.h (2 * tOff)))

repChar : Nat -> Char -> List Char
repChar Z     _ = []
repChar (S n) c = c :: repChar n c

drawBorder : BorderKind -> Maybe String -> WRect -> String
drawBorder NoBorder _ _ = ""
drawBorder kind titleM r =
  let (tl,tr,bl,br,hc,vc) = chars kind
      titleStr = case titleM of Nothing => ""; Just t => " " ++ sanitizeText t ++ " "
      topFillN = sub (sub r.w 2) (length titleStr)
      topLine  = pack [tl] ++ titleStr ++ pack (repChar topFillN hc) ++ pack [tr]
      botLine  = pack [bl] ++ pack (repChar (sub r.w 2) hc) ++ pack [br]
      sideRows = concatMap (sideRow vc) [r.row + 1 .. (r.row + sub r.h 1) `minus` 1]
  in moveCursor r.col r.row ++ resetAttrs ++ topLine ++
     moveCursor r.col (r.row + sub r.h 1) ++ resetAttrs ++ botLine ++
     sideRows
  where
    chars : BorderKind -> (Char, Char, Char, Char, Char, Char)
    chars NoBorder      = (' ',' ',' ',' ',' ',' ')
    chars ThinBorder    = ('┌','┐','└','┘','─','│')
    chars ThickBorder   = ('┏','┓','┗','┛','━','┃')
    chars RoundedBorder = ('╭','╮','╰','╯','─','│')

    sideRow : Char -> Nat -> String
    sideRow vc i =
      moveCursor r.col i ++ resetAttrs ++ pack [vc] ++
      moveCursor (r.col + sub r.w 1) i ++ pack [vc]

-- ─── Fill detection ──────────────────────────────────────────────────────────

public export
widgetFillH : Widget msg -> Bool
widgetFillH (WVStack s _)   = s.fillH
widgetFillH (WHStack s _)   = s.fillH
widgetFillH (WText s _)     = s.fillH
widgetFillH (WWrapText s _) = s.fillH
widgetFillH (WScroll s _ _ _) = s.fillH
widgetFillH (WInput s _ _)  = s.fillH
widgetFillH (WButton s _ _) = s.fillH
widgetFillH WSpacer         = True
widgetFillH _               = False

public export
widgetFillV : Widget msg -> Bool
widgetFillV (WVStack s _)   = s.fillV
widgetFillV (WHStack s _)   = s.fillV
widgetFillV (WText s _)     = s.fillV
widgetFillV (WWrapText s _) = s.fillV
widgetFillV (WScroll s _ _ _) = s.fillV
widgetFillV (WButton s _ _) = s.fillV
widgetFillV WSpacer         = True
widgetFillV _               = False

covering
ceilDiv : Nat -> Nat -> Nat
ceilDiv _ Z = 0
ceilDiv Z _ = 0
ceilDiv value divisor = S (ceilDiv (value `minus` divisor) divisor)

-- ─── Pass 1: measure (mutual recursion) ──────────────────────────────────────

mutual
  public export
  measure : Widget msg -> Nat -> Nat -> WSize
  measure w maxW maxH =
    let sz = natSize w maxW maxH
    in MkWSize (min sz.w maxW) (min sz.h maxH)

  natSize : Widget msg -> Nat -> Nat -> WSize
  natSize (WText s str) maxW _ =
    MkWSize (fromMaybeN (min (length str + hInset s) maxW) s.fixedW)
            (fromMaybeN (1 + vInset s) s.fixedH)

  natSize (WWrapText s str) maxW _ =
    let contentW = max 1 (maxW `minus` hInset s)
        lineCount = max 1 (ceilDiv (length str) contentW)
    in MkWSize (fromMaybeN maxW s.fixedW)
               (fromMaybeN (lineCount + vInset s) s.fixedH)

  natSize (WScroll s _ _ child) maxW maxH =
    MkWSize (fromMaybeN maxW s.fixedW) (fromMaybeN maxH s.fixedH)

  natSize (WInput s val _) maxW _ =
    MkWSize (fromMaybeN maxW s.fixedW)
            (fromMaybeN (1 + vInset s) s.fixedH)

  natSize (WButton s lbl _) maxW _ =
    let tw = length lbl + 2
    in MkWSize (fromMaybeN (tw + hInset s) s.fixedW)
               (fromMaybeN (1 + vInset s) s.fixedH)

  natSize (WCheckbox s _ _) maxW _ =
    MkWSize (fromMaybeN (4 + hInset s) s.fixedW)
            (fromMaybeN (1 + vInset s) s.fixedH)

  natSize (WProgress s _) maxW _ =
    MkWSize (fromMaybeN (min 24 maxW) s.fixedW)
            (fromMaybeN (1 + vInset s) s.fixedH)

  natSize (WSpinner s _) maxW _ =
    MkWSize (fromMaybeN (10 + hInset s) s.fixedW)
            (fromMaybeN (1 + vInset s) s.fixedH)

  natSize (WSparkline s _) maxW _ =
    MkWSize (fromMaybeN (min 26 maxW) s.fixedW)
            (fromMaybeN (1 + vInset s) s.fixedH)

  natSize (WDivider _) maxW _ = MkWSize maxW 1

  natSize WSpacer _ _ = MkWSize 0 0

  natSize (WVStack s children) maxW maxH =
    let fw = fromMaybeN maxW s.fixedW
        iW = sub fw (hInset s)
        css  = map (\c => measure c iW maxH) children
        totH = sum (map (.h) css)
        maxCW = foldl max 0 (map (.w) css)
    in MkWSize (fromMaybeN ((maxCW + hInset s) `min` maxW) s.fixedW)
               (fromMaybeN (totH + vInset s) s.fixedH)

  natSize (WHStack s children) maxW maxH =
    let fh = fromMaybeN maxH s.fixedH
        iH = sub fh (vInset s)
        css  = map (\c => measure c maxW iH) children
        totW = sum (map (.w) css)
        maxCH = foldl max 0 (map (.h) css)
    in MkWSize (fromMaybeN (totW + hInset s) s.fixedW)
               (fromMaybeN ((maxCH + vInset s) `min` maxH) s.fixedH)

-- ─── Fill distribution ───────────────────────────────────────────────────────

public export
irisZipWith : (a -> b -> c) -> List a -> List b -> List c
irisZipWith _ []         _          = []
irisZipWith _ _          []         = []
irisZipWith f (x :: xs) (y :: ys)   = f x y :: irisZipWith f xs ys

public export
distributeV : List (Widget msg) -> Nat -> Nat -> List WSize
distributeV children availW availH =
  let fixed = map (\c => if widgetFillV c then MkWSize 0 0 else measure c availW availH) children
      usedH = sum (map (.h) fixed)
      cnt   = length (filter widgetFillV children)
      each  = if cnt == 0 then 0 else natDiv (sub availH usedH) cnt
  in irisZipWith (\c, sz => if widgetFillV c then MkWSize availW each else sz)
                 children fixed

public export
distributeH : List (Widget msg) -> Nat -> Nat -> List WSize
distributeH children availW availH =
  let fixed = map (\c => if widgetFillH c then MkWSize 0 0 else measure c availW availH) children
      usedW = sum (map (.w) fixed)
      cnt   = length (filter widgetFillH children)
      each  = if cnt == 0 then 0 else natDiv (sub availW usedW) cnt
  in irisZipWith (\c, sz => if widgetFillH c then MkWSize each availH else sz)
                 children fixed

-- ─── Spinner frames ──────────────────────────────────────────────────────────

spinFrame : Nat -> String
spinFrame n =
  let frames = ["⠋","⠙","⠹","⠸","⠼","⠴","⠦","⠧","⠇","⠏"]
      idx = cast {to=Nat} (cast {to=Int} n `mod` 10)
  in case getAt idx frames of Nothing => "⠋"; Just s => s
  where
    getAt : Nat -> List a -> Maybe a
    getAt _     []        = Nothing
    getAt Z     (x :: _)  = Just x
    getAt (S k) (_ :: xs) = getAt k xs

-- ─── Progress bar ────────────────────────────────────────────────────────────

renderBar : Nat -> Double -> String
renderBar w frac =
  let fillN = cast {to=Nat} (cast {to=Int} (cast {to=Double} w * frac))
      emptyN = sub w fillN
      pct    = show (cast {to=Int} (frac * 100.0))
  in pack (repChar fillN '█' ++ repChar emptyN '░') ++ "  " ++ pct ++ "%"

-- ─── Sparkline ───────────────────────────────────────────────────────────────

sparkChar : Double -> Char
sparkChar v =
  let idx = cast {to=Nat} (cast {to=Int} (v * 7.0)) `min` 7
      cs  = ['▁','▂','▃','▄','▅','▆','▇','█']
  in case getAt idx cs of Nothing => '▁'; Just c => c
  where
    getAt : Nat -> List a -> Maybe a
    getAt _     []        = Nothing
    getAt Z     (x :: _)  = Just x
    getAt (S k) (_ :: xs) = getAt k xs

listTake : Nat -> List a -> List a
listTake Z     _        = []
listTake _     []       = []
listTake (S n) (x :: xs)= x :: listTake n xs

-- ─── Pad / truncate ──────────────────────────────────────────────────────────

padRight : Nat -> String -> String
padRight n s =
  let l = length s
  in if l >= n then substr 0 n s else s ++ pack (repChar (sub n l) ' ')

-- ─── Background fill ─────────────────────────────────────────────────────────

fillRows : Style -> WRect -> String
fillRows s r =
  concatMap (\i => moveCursor r.col (r.row + i) ++ styleAttrs s ++
                   pack (repChar r.w ' '))
            (range r.h)
  where
    range : Nat -> List Nat
    range Z     = []
    range (S n) = range n ++ [n]


-- ─── Pass 2: render (mutual with stack helpers) ──────────────────────────────

mutual
  public export
  renderWidget : Widget msg -> WRect -> String
  renderWidget (WText s str) r =
    let ir  = innerRect s r
        bg  = case s.bg of Nothing => ""; Just _ => fillRows s r
        brd = drawBorder s.border s.label r
    in bg ++ brd ++ moveCursor ir.col ir.row ++ styleAttrs s ++ padRight ir.w (sanitizeText str) ++ resetAttrs

  renderWidget (WWrapText s str) r =
    let ir  = innerRect s r
        bg  = case s.bg of Nothing => ""; Just _ => fillRows s r
        brd = drawBorder s.border s.label r
    in bg ++ brd ++ moveCursor ir.col ir.row ++ styleAttrs s ++ padRight ir.w (sanitizeText str) ++ resetAttrs

  renderWidget (WScroll s _ _ child) r =
    renderWidget child (innerRect s r)

  renderWidget (WInput s val _) r =
    let ir  = innerRect s r
        brd = drawBorder s.border s.label r
    in brd ++ moveCursor ir.col ir.row ++ styleAttrs s ++ padRight ir.w (sanitizeText val) ++ resetAttrs

  renderWidget (WButton s lbl _) r =
    let ir = innerRect s r
    in moveCursor ir.col ir.row ++ styleAttrs s ++ "[ " ++ sanitizeText lbl ++ " ]" ++ resetAttrs

  renderWidget (WCheckbox s checked _) r =
    let mark = if checked then "[x]" else "[ ]"
    in moveCursor r.col r.row ++ styleAttrs s ++ mark ++ resetAttrs

  renderWidget (WProgress s frac) r =
    let ir = innerRect s r
    in moveCursor ir.col ir.row ++ styleAttrs s ++ renderBar (sub ir.w 6) frac ++ resetAttrs

  renderWidget (WSpinner s tick) r =
    let ir = innerRect s r
    in moveCursor ir.col ir.row ++ styleAttrs s ++ spinFrame tick ++ " working" ++ resetAttrs

  renderWidget (WSparkline s vals) r =
    let ir   = innerRect s r
        line = pack (map sparkChar (listTake ir.w vals))
    in moveCursor ir.col ir.row ++ styleAttrs s ++ line ++ resetAttrs

  renderWidget (WDivider s) r =
    moveCursor r.col r.row ++ styleAttrs s ++ pack (repChar r.w '─') ++ resetAttrs

  renderWidget WSpacer _ = ""

  renderWidget (WVStack s children) r =
    let ir    = innerRect s r
        brd   = drawBorder s.border s.label r
        bg    = case s.bg of Nothing => ""; Just _ => fillRows s r
        sizes = distributeV children ir.w ir.h
    in bg ++ brd ++ renderVKids children sizes ir.col ir.row ir.w ir.h

  renderWidget (WHStack s children) r =
    let ir    = innerRect s r
        brd   = drawBorder s.border s.label r
        bg    = case s.bg of Nothing => ""; Just _ => fillRows s r
        sizes = distributeH children ir.w ir.h
    in bg ++ brd ++ renderHKids children sizes ir.col ir.row ir.w ir.h

  renderVKids : List (Widget msg) -> List WSize -> Nat -> Nat -> Nat -> Nat -> String
  renderVKids []         _          _   _   _    _    = ""
  renderVKids (c :: cs) (sz :: szs) col row maxW maxH =
    let cw = if widgetFillH c then maxW else min sz.w maxW
        ch = sz.h
    in renderWidget c (MkWRect col row cw ch) ++
       renderVKids cs szs col (row + ch) maxW (sub maxH ch)
  renderVKids (_ :: cs) [] col row maxW maxH =
    renderVKids cs [] col row maxW maxH

  renderHKids : List (Widget msg) -> List WSize -> Nat -> Nat -> Nat -> Nat -> String
  renderHKids []         _          _   _   _    _    = ""
  renderHKids (c :: cs) (sz :: szs) col row maxW maxH =
    let cw = sz.w
        ch = if widgetFillV c then maxH else min sz.h maxH
    in renderWidget c (MkWRect col row cw ch) ++
       renderHKids cs szs (col + cw) row (sub maxW cw) maxH
  renderHKids (_ :: cs) [] col row maxW maxH =
    renderHKids cs [] col row maxW maxH

-- ─── Top-level entry ─────────────────────────────────────────────────────────

||| Render a Widget to a full-screen ANSI string.
public export
renderScreen : Widget msg -> Nat -> Nat -> String
renderScreen w cols rows =
  clearScreen ++ cursorHome ++
  renderWidget w (MkWRect 0 0 cols rows) ++
  resetAttrs
