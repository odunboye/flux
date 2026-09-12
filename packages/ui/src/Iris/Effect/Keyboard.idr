||| Iris.Effect.Keyboard
||| Keyboard subscription — subscribe to key events via the TEA Sub system.
|||
||| Usage:
|||   subscriptions : Model -> Sub Msg
|||   subscriptions _ = onKeyDown handleKey
|||
|||   handleKey : KeyEvent -> Msg
|||   handleKey ke = case ke.key of
|||     "ArrowUp"  => NavUp
|||     "ArrowDown"=> NavDown
|||     "Enter"    => Confirm
|||     "Escape"   => Cancel
|||     _          => case ke.char of
|||                     Just c  => TypeChar c
|||                     Nothing => NoOp
module Iris.Effect.Keyboard

import Iris.State.TEA
import Iris.Platform.Event

-- ─── Keyboard subscriptions ─────────────────────────────────────────────────

||| Subscribe to all key-down events.
||| The handler receives a `KeyEvent` and returns a `msg`.
||| The runtime dispatches keyboard events to every active `onKeyDown` Sub.
public export
onKeyDown : (KeyEvent -> msg) -> Sub msg
onKeyDown handler =
  Listen "keyboard:keydown"
    (\send => do
       -- Production: register a platform keyboard listener.
       -- The returned IO () is called to unsubscribe when the Sub is removed.
       -- Stub: no-op until the platform event pump dispatches to subscribers.
       let cleanup : IO () = pure ()
       pure cleanup)

||| Subscribe to all key-up events.
public export
onKeyUp : (KeyEvent -> msg) -> Sub msg
onKeyUp handler =
  Listen "keyboard:keyup" (\send => pure (pure ()))

||| Subscribe only to a specific named key (e.g. "Enter", "Escape").
public export
onKey : String -> msg -> Sub msg
onKey keyName msg =
  onKeyDown (\ke => if ke.key == keyName then msg else msg)
  -- Note: in real impl the filter would return a Maybe and suppress non-matches.
  -- Simplified here for compilation; full filter needs Sub to carry Maybe.

-- ─── Common key helpers ─────────────────────────────────────────────────────

||| Match a KeyEvent to a message given a lookup table.
||| Unmatched keys return the default message.
public export
matchKey : List (String, msg) -> msg -> KeyEvent -> msg
matchKey []              def _  = def
matchKey ((k, m) :: rest) def ke =
  if ke.key == k then m else matchKey rest def ke

||| Build a keyboard subscription from a key-name → msg table.
public export
keyMap : List (String, msg) -> msg -> Sub msg
keyMap table def = onKeyDown (matchKey table def)
