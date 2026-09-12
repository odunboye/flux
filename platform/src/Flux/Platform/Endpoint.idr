module Flux.Platform.Endpoint

import public Flux.Middleware.JSON

%default covering

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
   in setStatus err.status . sendJSON
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
