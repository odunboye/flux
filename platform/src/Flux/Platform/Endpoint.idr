module Flux.Platform.Endpoint

import public Flux.Middleware.JSON

%default covering

||| Server-resolved identity. Never derive this from request JSON or an owner ID.
public export
record Principal where
  constructor MkPrincipal
  subjectId : String

||| Applications resolve an opaque credential against their durable session store.
||| Nothing means absent, expired or revoked credentials; infrastructure errors
||| should throw and remain redacted by rpcErrorRenderer, not authenticate a user.
public export
0 Authenticator : Type
Authenticator = Request -> AppProg (Maybe Principal)

||| Stable public RPC error envelope. Server errors are always redacted.
export
rpcErrorRenderer : ErrorRenderer
rpcErrorRenderer err =
  let code = case err.status of
        400 => "invalid_request"
        401 => "unauthenticated"
        403 => "forbidden"
        404 => "not_found"
        409 => "conflict"
        413 => "request_too_large"
        415 => "unsupported_media_type"
        429 => "rate_limited"
        _   => "internal_error"
      message = if err.status >= 500 then "Internal server error" else err.message
   in setHeader "Cache-Control" "no-store" . setStatus err.status . sendJSON
        (JObject [("error", JObject [("code", JString code), ("message", JString message)])])

||| Typed public endpoint adapter. Applications validate domain invariants in
||| the callback; FromJSON only establishes the wire representation's shape.
||| Install rpcErrorRenderer on the enclosing App. Authentication is not implied.
export
rpcHandler : FromJSON request => ToJSON response =>
             (request -> AppProg response) -> Handler
rpcHandler action ctx = do
  if isJSON ctx.request
    then do
      input <- requireJsonBody 65536 "Invalid request body" ctx
      output <- action input
      pure (sendJSON output ctx)
    else throw (MkAppError 415 "Expected application/json")

||| Authentication runs before body decoding and before any domain callback.
||| Route construction must supply an authenticator: there is no public fallback.
export
rpcAuthenticatedHandler : FromJSON request => ToJSON response =>
                          Authenticator -> (Principal -> request -> AppProg response) -> Handler
rpcAuthenticatedHandler authenticate action ctx = do
  Just principal <- authenticate ctx.request
    | Nothing => throw (MkAppError 401 "Authentication required")
  rpcHandler (action principal) (setHeader "Cache-Control" "no-store" ctx)
