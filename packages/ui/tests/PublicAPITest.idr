module Main

import Flux.UI
import System

color : Flux.UI.Widget.UIColor
color = Flux.UI.Widget.IBlue

command : Flux.UI.State.TEA.Cmd ()
command = none

app : Flux.UI.App.UIApp Nat ()
app = MkApp (0, command)
            (\_, n => (S n, none))
            (\n => text (show n))
            (\_, _ => Nothing)
            Nothing

main : IO ()
main = do
  let (count, _) = app.update () 0
  case color of
    IBlue => if count == 1
                then putStrLn "PASS Flux UI public API, qualified types and model update"
                else exitFailure
    _ => exitFailure
