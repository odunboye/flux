||| Versioned, validated event wire format used by browser backends.
|||
||| Fields are separated by `|`. User supplied strings are encoded as dot-
||| separated Unicode code points, so they can never inject protocol fields.
module Flux.UI.App.EventWire

import Data.String
import Flux.UI.Platform.Event
import Flux.UI.Core.Types

%default total

public export
data WireError
  = EmptyPayload
  | UnknownEventVersion
  | UnknownEventTag String
  | WrongFieldCount String
  | InvalidNumber String
  | InvalidEnum String
  | ValueOutOfRange String
  | PayloadTooLarge
  | InvalidEventPayload -- retained for source compatibility

public export
wireVersion : String
wireVersion = "f1"

maxPayloadLength : Nat
maxPayloadLength = 65536

joinWith : String -> List String -> String
joinWith _ [] = ""
joinWith _ [x] = x
joinWith separator (x :: xs) = x ++ separator ++ joinWith separator xs

splitOn : Char -> String -> List String
splitOn separator value = map pack (go [] (unpack value))
  where
    go : List Char -> List Char -> List (List Char)
    go acc [] = [reverse acc]
    go acc (c :: cs) =
      if c == separator
         then reverse acc :: go [] cs
         else go (c :: acc) cs

encodeText : String -> String
encodeText value = joinWith "." (map (show . ord) (unpack value))

decodeText : String -> Either WireError String
decodeText "" = Right ""
decodeText value = map pack (traverse decodeCodePoint (splitOn '.' value))
  where
    decodeCodePoint : String -> Either WireError Char
    decodeCodePoint raw =
      case parseInteger raw of
        Nothing => Left (InvalidNumber "text code point")
        Just n => if n < 0 || n > 1114111 || (n >= 55296 && n <= 57343)
                     then Left (ValueOutOfRange "text code point")
                     else Right (chr (cast n))

encodeBool : Bool -> String
encodeBool False = "0"
encodeBool True = "1"

decodeBool : String -> Either WireError Bool
decodeBool "0" = Right False
decodeBool "1" = Right True
decodeBool _ = Left (InvalidEnum "boolean")

encodeModifiers : ModifierKeys -> List String
encodeModifiers m = map encodeBool [m.shift, m.ctrl, m.alt, m.meta]

decodeModifiers : List String -> Either WireError ModifierKeys
decodeModifiers [shift, ctrl, alt, meta] =
  [| MkModifiers (decodeBool shift) (decodeBool ctrl) (decodeBool alt) (decodeBool meta) |]
decodeModifiers _ = Left (WrongFieldCount "modifiers")

keyActionName : KeyAction -> String
keyActionName KeyDown = "down"
keyActionName KeyUp = "up"
keyActionName KeyRepeat = "repeat"

decodeKeyAction : String -> Either WireError KeyAction
decodeKeyAction "down" = Right KeyDown
decodeKeyAction "up" = Right KeyUp
decodeKeyAction "repeat" = Right KeyRepeat
decodeKeyAction _ = Left (InvalidEnum "key action")

pointerActionName : PointerAction -> String
pointerActionName PointerDown = "down"
pointerActionName PointerUp = "up"
pointerActionName PointerMove = "move"
pointerActionName PointerEnter = "enter"
pointerActionName PointerLeave = "leave"
pointerActionName PointerCancel = "cancel"

decodePointerAction : String -> Either WireError PointerAction
decodePointerAction "down" = Right PointerDown
decodePointerAction "up" = Right PointerUp
decodePointerAction "move" = Right PointerMove
decodePointerAction "enter" = Right PointerEnter
decodePointerAction "leave" = Right PointerLeave
decodePointerAction "cancel" = Right PointerCancel
decodePointerAction _ = Left (InvalidEnum "pointer action")

pointerKindName : PointerKind -> String
pointerKindName Mouse = "mouse"
pointerKindName Touch = "touch"
pointerKindName Pen = "pen"

decodePointerKind : String -> Either WireError PointerKind
decodePointerKind "mouse" = Right Mouse
decodePointerKind "touch" = Right Touch
decodePointerKind "pen" = Right Pen
decodePointerKind _ = Left (InvalidEnum "pointer kind")

buttonName : Maybe PointerButton -> String
buttonName Nothing = "none"
buttonName (Just PrimaryBtn) = "primary"
buttonName (Just SecondaryBtn) = "secondary"
buttonName (Just MiddleBtn) = "middle"
buttonName (Just BackBtn) = "back"
buttonName (Just ForwardBtn) = "forward"

decodeButton : String -> Either WireError (Maybe PointerButton)
decodeButton "none" = Right Nothing
decodeButton "primary" = Right (Just PrimaryBtn)
decodeButton "secondary" = Right (Just SecondaryBtn)
decodeButton "middle" = Right (Just MiddleBtn)
decodeButton "back" = Right (Just BackBtn)
decodeButton "forward" = Right (Just ForwardBtn)
decodeButton _ = Left (InvalidEnum "pointer button")

parseIntField : String -> String -> Either WireError Int
parseIntField name raw = maybe (Left (InvalidNumber name)) (Right . cast) (parseInteger raw)

parseDoubleField : String -> String -> Either WireError Double
parseDoubleField name raw = maybe (Left (InvalidNumber name)) Right (parseDouble raw)

coordinate : String -> String -> Either WireError Double
coordinate name raw = do
  value <- parseDoubleField name raw
  if value /= value || value < -1000000000.0 || value > 1000000000.0
     then Left (ValueOutOfRange name)
     else Right value

nonNegative : String -> String -> Either WireError Double
nonNegative name raw = do
  value <- coordinate name raw
  if value < 0.0 then Left (ValueOutOfRange name) else Right value

pressureValue : String -> Either WireError Double
pressureValue raw = do
  value <- parseDoubleField "pressure" raw
  if value /= value || value < 0.0 || value > 1.0
     then Left (ValueOutOfRange "pressure")
     else Right value

charField : Maybe Char -> String
charField Nothing = "none"
charField (Just c) = show (ord c)

decodeChar : String -> Either WireError (Maybe Char)
decodeChar "none" = Right Nothing
decodeChar raw = do
  value <- parseIntField "character" raw
  if value < 0 || value > 1114111 || (value >= 55296 && value <= 57343)
     then Left (ValueOutOfRange "character")
     else Right (Just (chr value))

public export
encodeKey : KeyEvent -> String
encodeKey key = joinWith "|" $ [wireVersion, "K", keyActionName key.action,
  encodeText key.key, encodeText key.code] ++ encodeModifiers key.modifiers ++ [charField key.char]

public export
encodeEvent : Event -> String
encodeEvent (KeyboardEvent key) = encodeKey key
encodeEvent (PointerEvt pointer) = joinWith "|" $
  [ wireVersion, "P", pointerActionName pointer.action, pointerKindName pointer.kind
  , show pointer.id, show pointer.position.x, show pointer.position.y
  , show pointer.delta.x, show pointer.delta.y, buttonName pointer.button
  , show pointer.pressure
  ] ++ encodeModifiers pointer.modifiers
encodeEvent (ScrollEvt scroll) = joinWith "|"
  [wireVersion, "S", show scroll.position.x, show scroll.position.y,
   show scroll.deltaX, show scroll.deltaY, show scroll.deltaZ]
encodeEvent (WindowEvt (WindowResized size)) =
  joinWith "|" [wireVersion, "R", show size.width, show size.height]
encodeEvent (WindowEvt WindowFocusGained) = "f1|F|gain"
encodeEvent (WindowEvt WindowFocusLost) = "f1|F|lost"
encodeEvent (WindowEvt WindowCloseRequested) = "f1|W|close"
encodeEvent (WindowEvt (WindowFullscreenChanged value)) =
  joinWith "|" [wireVersion, "W", "fullscreen", encodeBool value]
encodeEvent (WindowEvt (WindowOrientationChanged Portrait)) = "f1|O|portrait"
encodeEvent (WindowEvt (WindowOrientationChanged Landscape)) = "f1|O|landscape"
encodeEvent (LifecycleEvt PageVisible) = "f1|L|visible"
encodeEvent (LifecycleEvt PageHidden) = "f1|L|hidden"
encodeEvent (LifecycleEvt AppPaused) = "f1|L|pause"
encodeEvent (LifecycleEvt AppResumed) = "f1|L|resume"
encodeEvent (LifecycleEvt BackRequested) = "f1|L|back"
encodeEvent (LifecycleEvt (LocationChanged url)) =
  joinWith "|" [wireVersion, "L", "location", encodeText url]
encodeEvent (CompositionEvt composition) = joinWith "|"
  [wireVersion, "M", compositionName composition.action, encodeText composition.text]
  where
    compositionName : CompositionAction -> String
    compositionName CompositionStart = "start"
    compositionName CompositionUpdate = "update"
    compositionName CompositionEnd = "end"
    compositionName CompositionCancel = "cancel"
encodeEvent (TextInput text) = joinWith "|" [wireVersion, "T", encodeText text]
encodeEvent (Tick timestamp) = joinWith "|" [wireVersion, "D", show timestamp]
encodeEvent (Custom payload) = joinWith "|" [wireVersion, "X", encodeText payload]

public export
encodeFocus : Bool -> String
encodeFocus True = encodeEvent (WindowEvt WindowFocusGained)
encodeFocus False = encodeEvent (WindowEvt WindowFocusLost)

decodeKeyFields : List String -> Either WireError Event
decodeKeyFields [action, key, code, shift, ctrl, alt, meta, char] = do
  decodedKey <- decodeText key
  if decodedKey == "" then Left (InvalidEventPayload) else do
    decodedCode <- decodeText code
    keyAction <- decodeKeyAction action
    modifiers <- decodeModifiers [shift, ctrl, alt, meta]
    character <- decodeChar char
    Right (KeyboardEvent (MkKeyEvent keyAction decodedKey decodedCode modifiers character))
decodeKeyFields _ = Left (WrongFieldCount "keyboard")

decodePointerFields : List String -> Either WireError Event
decodePointerFields [action, kind, id, x, y, dx, dy, button, pressure, shift, ctrl, alt, meta] = do
  pointerId <- parseIntField "pointer id" id
  if pointerId < 0 then Left (ValueOutOfRange "pointer id") else do
    px <- coordinate "pointer x" x
    py <- coordinate "pointer y" y
    mx <- coordinate "movement x" dx
    my <- coordinate "movement y" dy
    decodedPressure <- pressureValue pressure
    decodedAction <- decodePointerAction action
    decodedKind <- decodePointerKind kind
    decodedButton <- decodeButton button
    modifiers <- decodeModifiers [shift, ctrl, alt, meta]
    Right (PointerEvt (MkPointerEvent decodedAction decodedKind pointerId
      (MkPoint px py) (MkPoint mx my) decodedButton decodedPressure modifiers))
decodePointerFields _ = Left (WrongFieldCount "pointer")

decodeCompositionAction : String -> Either WireError CompositionAction
decodeCompositionAction "start" = Right CompositionStart
decodeCompositionAction "update" = Right CompositionUpdate
decodeCompositionAction "end" = Right CompositionEnd
decodeCompositionAction "cancel" = Right CompositionCancel
decodeCompositionAction _ = Left (InvalidEnum "composition action")

decodeFields : String -> List String -> Either WireError Event
decodeFields "K" fields = decodeKeyFields fields
decodeFields "P" fields = decodePointerFields fields
decodeFields "S" [x, y, dx, dy, dz] = do
  px <- coordinate "scroll x" x
  py <- coordinate "scroll y" y
  deltaX <- coordinate "scroll delta x" dx
  deltaY <- coordinate "scroll delta y" dy
  deltaZ <- coordinate "scroll delta z" dz
  Right (ScrollEvt (MkScrollEvent (MkPoint px py) deltaX deltaY deltaZ))
decodeFields "S" _ = Left (WrongFieldCount "scroll")
decodeFields "R" [width, height] = do
  decodedWidth <- nonNegative "width" width
  decodedHeight <- nonNegative "height" height
  Right (WindowEvt (WindowResized (MkSize decodedWidth decodedHeight)))
decodeFields "R" _ = Left (WrongFieldCount "resize")
decodeFields "F" ["gain"] = Right (WindowEvt WindowFocusGained)
decodeFields "F" ["lost"] = Right (WindowEvt WindowFocusLost)
decodeFields "F" [_] = Left (InvalidEnum "focus")
decodeFields "F" _ = Left (WrongFieldCount "focus")
decodeFields "W" ["close"] = Right (WindowEvt WindowCloseRequested)
decodeFields "W" ["fullscreen", value] = map (WindowEvt . WindowFullscreenChanged) (decodeBool value)
decodeFields "W" (_ :: _) = Left (InvalidEnum "window event")
decodeFields "W" _ = Left (WrongFieldCount "window event")
decodeFields "O" ["portrait"] = Right (WindowEvt (WindowOrientationChanged Portrait))
decodeFields "O" ["landscape"] = Right (WindowEvt (WindowOrientationChanged Landscape))
decodeFields "O" [_] = Left (InvalidEnum "orientation")
decodeFields "O" _ = Left (WrongFieldCount "orientation")
decodeFields "L" ["visible"] = Right (LifecycleEvt PageVisible)
decodeFields "L" ["hidden"] = Right (LifecycleEvt PageHidden)
decodeFields "L" ["pause"] = Right (LifecycleEvt AppPaused)
decodeFields "L" ["resume"] = Right (LifecycleEvt AppResumed)
decodeFields "L" ["back"] = Right (LifecycleEvt BackRequested)
decodeFields "L" ["location", url] = map (LifecycleEvt . LocationChanged) (decodeText url)
decodeFields "L" [_] = Left (InvalidEnum "lifecycle event")
decodeFields "L" _ = Left (WrongFieldCount "lifecycle event")
decodeFields "M" [action, text] = do
  decodedAction <- decodeCompositionAction action
  decodedText <- decodeText text
  Right (CompositionEvt (MkCompositionEvent decodedAction decodedText))
decodeFields "M" _ = Left (WrongFieldCount "composition")
decodeFields "T" [text] = map TextInput (decodeText text)
decodeFields "T" _ = Left (WrongFieldCount "text input")
decodeFields "D" [timestamp] = do
  value <- nonNegative "timestamp" timestamp
  Right (Tick value)
decodeFields "D" _ = Left (WrongFieldCount "tick")
decodeFields "X" [payload] = map Custom (decodeText payload)
decodeFields "X" _ = Left (WrongFieldCount "custom")
decodeFields tag _ = Left (UnknownEventTag tag)

public export
decodeEventEither : String -> Either WireError Event
decodeEventEither raw =
  if raw == "" then Left EmptyPayload
  else if length raw > maxPayloadLength then Left PayloadTooLarge
  else case splitOn '|' raw of
         version :: tag :: fields =>
           if version /= wireVersion
              then Left UnknownEventVersion
              else decodeFields tag fields
         version :: _ => if version /= wireVersion
                            then Left UnknownEventVersion
                            else Left InvalidEventPayload
         [] => Left EmptyPayload

public export
decodeEvent : String -> Maybe Event
decodeEvent raw = either (const Nothing) Just (decodeEventEither raw)

public export
decodeKey : String -> Maybe KeyEvent
decodeKey raw =
  case decodeEvent raw of
    Just (KeyboardEvent key) => Just key
    _ => Nothing
