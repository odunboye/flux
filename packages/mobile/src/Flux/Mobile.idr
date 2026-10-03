||| Optional native effects for Flux's existing DOM/Canvas WebView renderers.
||| Import this module, not Capacitor, in applications. No server dependency.
module Flux.Mobile

import public Capacitor
import public Flux.UI.State.TEA
import Data.IORef
import Control.Monad.MErr

%default covering

||| Mobile errors are explicit application messages, never success fallbacks.
public export
record MobileError where
  constructor MkMobileError
  message : String

||| Adapt a typed plugin operation to one cancellable Flux command.
||| Cancellation suppresses delivery; it cannot undo an SDK operation already
||| started. The operation runs once, without automatic retry or resume replay.
export
perform : Async JS [JSErr] a -> (Either MobileError a -> msg) -> Cmd msg
perform operation result = CancellableTask $ \send => do
  alive <- newIORef True
  app $ do
    outcome <- liftError operation
    live <- readIORef alive
    if live then primIO (toPrim (send (result (case outcome of
      Left error => Left (MkMobileError (dispErr error))
      Right value => Right value)))) else pure ()
  pure (writeIORef alive False)

export
toastCommand : ToastOptions -> (Either MobileError () -> msg) -> Cmd msg
toastCommand options = perform (showToast options)

export
alertCommand : AlertOptions -> (Either MobileError () -> msg) -> Cmd msg
alertCommand options = perform (alert options)

export
confirmCommand : ConfirmOptions -> (Either MobileError ConfirmResult -> msg) -> Cmd msg
confirmCommand options = perform (confirm options)

export
promptCommand : PromptOptions -> (Either MobileError PromptResult -> msg) -> Cmd msg
promptCommand options = perform (prompt options)

export
actionSheetCommand : ActionSheetOptions -> (Either MobileError ActionSheetResult -> msg) -> Cmd msg
actionSheetCommand options = perform (showActions options)

export
networkStatusCommand : (Either MobileError NetworkStatus -> msg) -> Cmd msg
networkStatusCommand = perform getStatus

export
deviceInfoCommand : (Either MobileError DeviceInfo -> msg) -> Cmd msg
deviceInfoCommand = perform getDeviceInfo

export
batteryInfoCommand : (Either MobileError BatteryInfo -> msg) -> Cmd msg
batteryInfoCommand = perform getBatteryInfo

export
deviceIdCommand : (Either MobileError String -> msg) -> Cmd msg
deviceIdCommand = perform getDeviceId

||| Owned network events for UIApp's init command. Flux disposes the listener on
||| pause/shutdown/HMR. Restart explicitly on resume if the application needs it.
export
networkChanges : (Either MobileError NetworkStatus -> msg) -> Cmd msg
networkChanges result = CancellableTask $ \send => do
  alive <- newIORef True
  let deliver : Either MobileError NetworkStatus -> IO ()
      deliver value = do
        live <- readIORef alive
        if live then send (result value) else pure ()
  stop <- monitorNetwork (\status => deliver (Right status))
                         (\error => deliver (Left (MkMobileError error)))
  pure (do writeIORef alive False; stop)

||| For the TEA App subscription API. Use a stable, application-owned key.
export
networkSubscription : String -> (Either MobileError NetworkStatus -> msg) -> Sub msg
networkSubscription key result = Listen key $ \send =>
  case networkChanges result of
    CancellableTask register => register send
    _ => pure (pure ())
