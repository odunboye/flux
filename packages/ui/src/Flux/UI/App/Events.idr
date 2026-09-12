||| Optional platform-event compatibility layer for Flux UI applications.
|||
||| Existing UIApp values remain source-compatible. Applications that need
||| pointer, resize, focus, scroll, or lifecycle events can wrap one in an
||| EventApp without changing their existing update/view definitions.
module Flux.UI.App.Events

import Data.IORef
import Flux.UI.App
import Flux.UI.Platform.Event
import Flux.UI.Runtime.Common

public export
record EventApp (model : Type) (msg : Type) where
  constructor MkEventApp
  base        : UIApp model msg
  handleEvent : model -> Event -> Maybe msg

||| Wrap an existing application with a platform-event handler.
public export
withEvents : UIApp model msg
          -> (model -> Event -> Maybe msg)
          -> EventApp model msg
withEvents app handler = MkEventApp app handler

public export
dispatchEvent : EventApp model msg -> IORef model -> IORef Bool -> Event -> IO ()
dispatchEvent app modelRef quitRef event = do
  model <- readIORef modelRef
  case app.handleEvent model event of
    Nothing  => pure ()
    Just msg => dispatch app.base modelRef quitRef msg

public export
keyboardEvents : EventApp model msg -> model -> KeyEvent -> Maybe msg
keyboardEvents app model key =
  case app.handleEvent model (KeyboardEvent key) of
    Just msg => Just msg
    Nothing  => app.base.handleEvent model (KeyboardEvent key)
