-- Generated protocol SHA-256: 84e79e50e654d4864c214c9cf335828ab6f308f82fe6eb476b6e975696866226. Do not edit.
module Protocol

import public ProtocolTypes
import public Flux.Platform.Endpoint
import public Flux.Core.Router

%default covering

public export
record Api where
  constructor MkApi
  privateProbe : Principal -> ProbeRequest -> AppProg ProbeResponse
  publicProbe : ProbeRequest -> AppProg ProbeResponse

-- Applications choose CORS policy; this supplies the preflight status.
preflight : Handler
preflight ctx = pure (setStatus 204 ctx)

export
routes : Authenticator -> Api -> Router Handler
routes authenticate api = empty
  |> post "/rpc/v1/probe/private" (rpcAuthenticatedHandler authenticate api.privateProbe)
  |> options_ "/rpc/v1/probe/private" preflight
  |> post "/rpc/v1/probe/public" (rpcHandler api.publicProbe)
  |> options_ "/rpc/v1/probe/public" preflight
