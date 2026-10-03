module Main

import System
import Data.String
import Flux.UI.App.EventWire
import Flux.UI.Platform.Event
import Flux.UI.Core.Types

mods : ModifierKeys
mods = MkModifiers True False True False

roundTrips : List Event
roundTrips =
  [ KeyboardEvent (MkKeyEvent KeyDown "a|:λ" "KeyA" mods (Just 'a'))
  , KeyboardEvent (MkKeyEvent KeyUp "Enter" "Enter" mods Nothing)
  , KeyboardEvent (MkKeyEvent KeyRepeat "x" "KeyX" mods (Just 'x'))
  , PointerEvt (MkPointerEvent PointerDown Mouse 0 (MkPoint 1.5 2.5)
      (MkPoint 0.0 0.0) (Just PrimaryBtn) 0.5 mods)
  , PointerEvt (MkPointerEvent PointerUp Touch 12 (MkPoint 10.0 20.0)
      (MkPoint 1.0 (-2.0)) Nothing 1.0 mods)
  , PointerEvt (MkPointerEvent PointerMove Pen 2 (MkPoint 3.0 4.0)
      (MkPoint 1.0 1.0) (Just SecondaryBtn) 0.25 mods)
  , PointerEvt (MkPointerEvent PointerEnter Mouse 1 (MkPoint 0.0 0.0)
      (MkPoint 0.0 0.0) (Just MiddleBtn) 0.0 mods)
  , PointerEvt (MkPointerEvent PointerLeave Mouse 1 (MkPoint 0.0 0.0)
      (MkPoint 0.0 0.0) (Just BackBtn) 0.0 mods)
  , PointerEvt (MkPointerEvent PointerCancel Touch 3 (MkPoint 0.0 0.0)
      (MkPoint 0.0 0.0) (Just ForwardBtn) 0.0 mods)
  , ScrollEvt (MkScrollEvent (MkPoint 20.0 30.0) 1.0 (-4.0) 0.0)
  , WindowEvt (WindowResized (MkSize 1024.0 768.0))
  , WindowEvt WindowFocusGained
  , WindowEvt WindowFocusLost
  , WindowEvt WindowCloseRequested
  , WindowEvt (WindowFullscreenChanged True)
  , WindowEvt (WindowOrientationChanged Portrait)
  , WindowEvt (WindowOrientationChanged Landscape)
  , LifecycleEvt PageVisible
  , LifecycleEvt PageHidden
  , LifecycleEvt AppPaused
  , LifecycleEvt AppResumed
  , LifecycleEvt BackRequested
  , LifecycleEvt (LocationChanged "/tasks?page=2#active")
  , CompositionEvt (MkCompositionEvent CompositionStart "")
  , CompositionEvt (MkCompositionEvent CompositionUpdate "に|ほん")
  , CompositionEvt (MkCompositionEvent CompositionEnd "日本")
  , CompositionEvt (MkCompositionEvent CompositionCancel "x")
  , TextInput "text|with:delimiters λ"
  , Tick 1234.5
  , Custom "custom|payload"
  ]

checkRoundTrip : Event -> Bool
checkRoundTrip event =
  case decodeEventEither (encodeEvent event) of
    Right decoded => encodeEvent decoded == encodeEvent event
    Left _ => False

invalidCases : List (String, WireError -> Bool)
invalidCases =
  [ ("", \case EmptyPayload => True; _ => False)
  , ("f2|T|65", \case UnknownEventVersion => True; _ => False)
  , ("i1|L|resume", \case UnknownEventVersion => True; _ => False)
  , ("f1|wat", \case UnknownEventTag "wat" => True; _ => False)
  , ("f1|R|10", \case WrongFieldCount "resize" => True; _ => False)
  , ("f1|R|abc|10", \case InvalidNumber "width" => True; _ => False)
  , ("f1|R|-1|10", \case ValueOutOfRange "width" => True; _ => False)
  , ("f1|P|down|mouse|-1|0|0|0|0|none|0|0|0|0|0",
      \case ValueOutOfRange "pointer id" => True; _ => False)
  , ("f1|P|down|mouse|1|0|0|0|0|none|1.1|0|0|0|0",
      \case ValueOutOfRange "pressure" => True; _ => False)
  , ("f1|P|down|trackpad|1|0|0|0|0|none|0|0|0|0|0",
      \case InvalidEnum "pointer kind" => True; _ => False)
  , ("f1|T|not-a-codepoint", \case InvalidNumber "text code point" => True; _ => False)
  , ("f1|T|55296", \case ValueOutOfRange "text code point" => True; _ => False)
  , ("f1|D|-1", \case ValueOutOfRange "timestamp" => True; _ => False)
  , (pack (replicate 65537 'x'), \case PayloadTooLarge => True; _ => False)
  ]

checkInvalid : (String, WireError -> Bool) -> Bool
checkInvalid (wire, expected) =
  case decodeEventEither wire of
    Left error => expected error
    Right _ => False

allTrue : List Bool -> Bool
allTrue [] = True
allTrue (value :: rest) = value && allTrue rest

main : IO ()
main =
  if allTrue (map checkRoundTrip roundTrips) && allTrue (map checkInvalid invalidCases)
     then putStrLn "EventWire tests passed"
     else do
       putStrLn "EventWire tests failed"
       exitFailure
