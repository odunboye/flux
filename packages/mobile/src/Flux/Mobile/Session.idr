||| Native-only, origin-scoped credentials. Persist only a token and its intent;
||| identity and expiry must be checked against the server after every restore.
module Flux.Mobile.Session

import public Flux.Mobile
import JSON.Simple
import Data.String
import Data.List

%default covering

public export
data SavedSession = NoSavedSession | ActiveSession String | RevokingSession String

validToken : String -> Bool
validToken token = length token >= 32 && length token <= 512 &&
  all (\c => (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
              (c >= '0' && c <= '9') || c == '-' || c == '_') (unpack token)

export
decodeSavedSession : VaultSlot -> Either MobileError SavedSession
decodeSavedSession slot =
  if slot.value == "" then Right NoSavedSession else
    let invalid = Left (MkMobileError "Invalid saved session; clear this device's saved session to continue.") in
      case decodeMaybe {a = JSON} slot.value of
        Just (JObject fields) => if length fields /= 3 then invalid else
          case (lookup "version" fields, lookup "state" fields, lookup "token" fields) of
            (Just (JString "1"), Just (JString state), Just (JString token)) =>
              if not (validToken token) then invalid else case state of
                "active" => Right (ActiveSession token)
                "revoking" => Right (RevokingSession token)
                _ => invalid
            _ => invalid
        _ => invalid

export
openSessionCommand : String -> (Either MobileError (Maybe SessionVault) -> msg) -> Cmd msg
openSessionCommand origin = perform (openSessionVault origin)

export
readSessionCommand : SessionVault -> (Either MobileError VaultSlot -> msg) -> Cmd msg
readSessionCommand vault = perform (readVault vault)

||| Revoking is durable BEFORE issuing logout. A cold start must never authenticate
||| using a revoking record, or automatically replay server revocation.
export
saveSessionCommand : SessionVault -> VaultSlot -> Bool -> String -> (Either MobileError VaultSlot -> msg) -> Cmd msg
saveSessionCommand vault previous revoking token result =
  if not (validToken token) then perform (pure previous) (\_ => result (Left (MkMobileError "Invalid session token"))) else
    perform (writeVault vault previous (encode (JObject [("version", JString "1"),
      ("state", JString (if revoking then "revoking" else "active")), ("token", JString token)]))) result

export
clearSessionCommand : SessionVault -> (Either MobileError VaultSlot -> msg) -> Cmd msg
clearSessionCommand vault = perform (clearVault vault)
