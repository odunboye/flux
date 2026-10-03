module Main

import Flux.UI
import Flux.UI.Backend.Terminal.Run

public export
data Msg = Increment | Exit

update : Msg -> Nat -> (Nat, Cmd Msg)
update Increment count = (S count, none)
update Exit count = (count, quit)

view : Nat -> Widget Msg
view count = vstack
  [ text ("Count: " ++ show count)
  , WButton (sPad 1 defaultStyle) "Increment" Increment
  , WButton (sPad 1 defaultStyle) "Quit" Exit
  , text "Press i to increment; q to quit"
  ]

handleEvent : Nat -> Event -> Maybe Msg
handleEvent _ (KeyboardEvent ke) = case ke.action of
  KeyDown => case ke.key of
    "i" => Just Increment
    "q" => Just Exit
    _ => Nothing
  _ => Nothing
handleEvent _ _ = Nothing

export
counter : UIApp Nat Msg
counter = MkApp (0, none) update view handleEvent Nothing

main : IO ()
main = runTUI counter
