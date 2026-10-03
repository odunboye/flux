module Main

import Flux.Mobile
import Flux.Mobile.Session

%default covering

%foreign "browser:lambda: value => { globalThis.mobileResults.push(value); }"
prim__record : String -> PrimIO ()

%foreign "browser:lambda: (stop,w) => { globalThis.stopMobile = () => stop(w); }"
prim__saveStop : PrimIO () -> PrimIO ()

start : Cmd String -> IO (IO ())
start (CancellableTask register) = register (\value => primIO (prim__record value))
start _ = pure (pure ())

vaultFlow : Async JS [JSErr] String
vaultFlow = do
  Just vault <- openSessionVault "https://api.example.test"
    | Nothing => pure "vault unexpectedly used web mode"
  first <- readVault vault
  saved <- writeVault vault first "opaque fixture"
  cleared <- clearVault vault
  pure (if first.value == "" && saved.value == "opaque fixture" && cleared.value == "" &&
           first.revision /= saved.revision && saved.revision /= cleared.revision
          then "vault ffi:passed" else "vault ffi:failed")

main : IO ()
main = do
  let valid = decodeSavedSession (MkVaultSlot "unused" "{\"version\":\"1\",\"state\":\"revoking\",\"token\":\"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\"}")
  primIO (prim__record (case valid of Right (RevokingSession _) => "vault codec:passed"; _ => "vault codec:failed"))
  let invalid = decodeSavedSession (MkVaultSlot "unused" "{\"version\":\"1\",\"state\":\"active\",\"token\":\"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\",\"account\":\"untrusted\"}")
  primIO (prim__record (case invalid of Left _ => "vault metadata:rejected"; _ => "vault metadata:accepted"))
  _ <- start (perform vaultFlow (\result => case result of Right value => value; Left _ => "vault ffi:error"))
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
