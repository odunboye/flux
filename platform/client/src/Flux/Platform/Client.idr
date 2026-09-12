||| Portable RPC client glue for Iris. No Flux server or PostgreSQL dependency.
module Flux.Platform.Client

import public Iris.State.TEA
import public Iris.Effect.Http
import public JSON.Simple

%default covering

public export
data RpcError
  = TransportFailure HttpError
  | RemoteError Int String String
  | InvalidResponse String

public export
Transport : Type
Transport = {msg : Type} -> HttpRequest -> (Either HttpError HttpResponse -> msg) -> Cmd msg

public export
record Client where
  constructor MkClient
  baseUrl : String
  send : Transport

record WireError where
  constructor MkWireError
  code : String
  message : String

FromJSON WireError where
  fromJSON = withObject "RPC error" $ \obj =>
    MkWireError <$> field obj "code" <*> field obj "message"

record ErrorEnvelope where
  constructor MkErrorEnvelope
  error : WireError

FromJSON ErrorEnvelope where
  fromJSON = withObject "RPC error envelope" $ \obj =>
    MkErrorEnvelope <$> field obj "error"

remoteError : Int -> String -> RpcError
remoteError status body = case decodeMaybe {a = ErrorEnvelope} body of
  Just envelope => RemoteError status envelope.error.code envelope.error.message
  Nothing => InvalidResponse "Invalid RPC error envelope"

||| Transport errors remain distinguishable from remote application errors.
||| Do not include an untrusted raw response body in decoder error messages.
export
decodeResponse : FromJSON response => Either HttpError HttpResponse -> Either RpcError response
decodeResponse (Left (BadStatus status body)) = Left (remoteError status body)
decodeResponse (Left err) = Left (TransportFailure err)
decodeResponse (Right response) =
  if response.status == 200 then case decodeMaybe response.body of
    Just value => Right value
    Nothing => Left (InvalidResponse "Invalid RPC response body")
  else Left (remoteError response.status response.body)

||| Produces an Iris Cmd rather than running HTTP eagerly. Mapping the result
||| does not unwrap the command, so Web CancellableTask ownership is preserved.
export
call : {msg : Type} -> ToJSON req => FromJSON res => Client -> String -> req ->
       (Either RpcError res -> msg) -> Cmd msg
call client path input toMsg =
  let base = pack (reverse (dropWhile (== '/') (reverse (unpack client.baseUrl))))
      request = MkRequest POST (base ++ path) [("Content-Type", "application/json")]
                          (Just (encode input))
   in client.send request (toMsg . decodeResponse)
