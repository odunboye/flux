module Main

import Flux.Mobile

%default covering

%foreign "browser:lambda: value => { globalThis.mobileResults.push(value); }"
prim__record : String -> PrimIO ()

%foreign "browser:lambda: (stop,w) => { globalThis.stopMobile = () => stop(w); }"
prim__saveStop : PrimIO () -> PrimIO ()

start : Cmd String -> IO (IO ())
start (CancellableTask register) = register (\value => primIO (prim__record value))
start _ = pure (pure ())

main : IO ()
main = do
  cancelled <- start (networkStatusCommand (\_ => "cancelled callback leaked"))
  cancelled
  _ <- start (networkStatusCommand (\result => case result of
    Left error => "error:" ++ error.message
    Right value => "connected:" ++ show value.connected))
  _ <- start (actionSheetCommand (MkActionSheetOptions "Choose" "" [MkButton "", MkButton "Share", MkButton "£ / ₦"])
    (\result => case result of
      Left error => "error:" ++ error.message
      Right value => "selected:" ++ show value.index))
  _ <- start (confirmCommand (MkConfirmOptions "Confirm" "test" "OK" "Cancel")
    (\result => case result of
      Left error => "expected error:" ++ error.message
      Right _ => "malformed confirmation accepted"))
  stop <- start (networkChanges (\result => case result of
    Left error => "listener error:" ++ error.message
    Right value => "network:" ++ show value.connected))
  primIO (prim__saveStop (toPrim stop))
