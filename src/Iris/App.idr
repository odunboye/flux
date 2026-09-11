||| Iris.App
||| The single universal application record used by every backend.
|||
||| Replacing backend-specific TUIApp / WebApp with one type means
||| the same value can be passed to `runTUI`, `runWeb`, `runDesktop`,
||| or `runMobile` — write once, run anywhere.
module Iris.App

import Iris.State.TEA
import Iris.Platform.Event
import Iris.Widget

||| A complete Iris application.
|||
||| @ model  — the application state type
||| @ msg    — the message / action type
public export
record IrisApp (model : Type) (msg : Type) where
  constructor MkApp
  ||| Initial model and any startup commands.
  init          : (model, Cmd msg)
  ||| Pure state transition: message × old model → new model + effects.
  update        : msg -> model -> (model, Cmd msg)
  ||| Pure view: current model → abstract widget tree.
  ||| The backend renders this tree into its native format.
  view          : model -> Widget msg
  ||| Keyboard input dispatch.
  ||| `ke.key` uses browser KeyboardEvent.key naming on every backend
  ||| ("ArrowUp", "Enter", "Backspace", "a", " ", …).
  handleEvent   : model -> Event -> Maybe msg
  ||| Optional animation tick message dispatched every ~100 ms.
  ||| Use this to drive spinners, progress animations, etc.
  tickMsg       : Maybe msg
