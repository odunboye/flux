||| Versioned, validated event wire format used by browser backends.
module Iris.App.EventWire

import Iris.Platform.Event
import Iris.Core.Types

public export
data WireError = EmptyPayload | UnknownEventVersion | InvalidEventPayload

public export
wireVersion : String
wireVersion = "i1"

public export
encodeKey : KeyEvent -> String
encodeKey k = wireVersion ++ ":K:" ++ k.key

public export
encodeEvent : Event -> String
encodeEvent (KeyboardEvent key) = encodeKey key
encodeEvent (TextInput text) = wireVersion ++ ":T:" ++ text
encodeEvent (WindowEvt WindowFocusGained) = wireVersion ++ ":F:gain"
encodeEvent (WindowEvt WindowFocusLost) = wireVersion ++ ":F:lost"
encodeEvent (Custom payload) = wireVersion ++ ":X:" ++ payload
encodeEvent _ = wireVersion ++ ":X:unsupported"

public export
decodeKey : String -> Maybe KeyEvent
decodeKey raw =
  case unpack raw of
    ('i' :: '1' :: ':' :: 'K' :: ':' :: rest) =>
      let key = pack rest
          ch = case unpack key of [c] => Just c; _ => Nothing
      in if key == "" then Nothing
         else Just (MkKeyEvent KeyDown key key (MkModifiers False False False False) ch)
    _ => Nothing

public export
decodeEvent : String -> Maybe Event
decodeEvent raw =
  case raw of
    "i1:F:gain" => Just (WindowEvt WindowFocusGained)
    "i1:F:lost" => Just (WindowEvt WindowFocusLost)
    _ => case unpack raw of
           ('i' :: '1' :: ':' :: 'T' :: ':' :: chars) => Just (TextInput (pack chars))
           _ => map KeyboardEvent (decodeKey raw)

public export
decodeEventEither : String -> Either WireError Event
decodeEventEither raw =
  case unpack raw of
    [] => Left EmptyPayload
    ('i' :: '1' :: ':' :: _) =>
      case decodeEvent raw of
        Just event => Right event
        Nothing => Left InvalidEventPayload
    _ => Left UnknownEventVersion

splitComma : List Char -> (List Char, List Char)
splitComma xs = go [] xs
  where
    go : List Char -> List Char -> (List Char, List Char)
    go acc [] = (reverse acc, [])
    go acc (',' :: rest) = (reverse acc, rest)
    go acc (x :: rest) = go (x :: acc) rest

decodeResize : String -> Maybe Event
decodeResize raw =
  case unpack raw of
    ('i' :: '1' :: ':' :: 'R' :: ':' :: rest) =>
      case splitComma rest of
        (w, [] ) => Nothing
        (w, h) =>
          let wi : Int = cast (pack w)
              he : Int = cast (pack h)
          in if wi < 0 || he < 0 then Nothing
             else Just (WindowEvt (WindowResized (MkSize (cast wi) (cast he))))
    _ => Nothing

public export
encodeFocus : Bool -> String
encodeFocus True  = wireVersion ++ ":F:gain"
encodeFocus False = wireVersion ++ ":F:lost"
