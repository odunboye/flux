||| Flux.UI.App
||| The single universal application record used by every backend.
|||
||| Supported runners: Terminal.Run.runTUI, Web.DOM.Run.runWeb and
||| Canvas.Run.runCanvas (runMobile uses the Canvas/WebView path).
||| Rendering, input and effect lifecycle behavior differ; see CAPABILITIES.md.
module Flux.UI.App

import Flux.UI.State.TEA
import Flux.UI.Platform.Event
import Flux.UI.Widget

||| A complete Flux UI application.
|||
||| @ model  — the application state type
||| @ msg    — the message / action type
public export
record UIApp (model : Type) (msg : Type) where
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
