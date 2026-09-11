||| Optional platform-event compatibility layer for Iris applications.
|||
||| Existing IrisApp values remain source-compatible. Applications that need
||| pointer, resize, focus, scroll, or lifecycle events can wrap one in an
||| EventApp without changing their existing update/view definitions.
module Iris.App.Events

import Data.IORef
import Iris.App
import Iris.Platform.Event
import Iris.Runtime.Common

public export
record EventApp (model : Type) (msg : Type) where
  constructor MkEventApp
  base        : IrisApp model msg
  handleEvent : model -> Event -> Maybe msg

||| Wrap an existing application with a platform-event handler.
public export
withEvents : IrisApp model msg
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
