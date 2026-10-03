module Flux.Platform.Client.Web

import public Flux.Platform.Client
import public Flux.UI.Effect.Http.Web

%default covering

||| Flux UI browser/Capacitor fetch transport with Flux UI-owned cancellation.
||| An empty base URL uses the current origin. Configure CORS at the server
||| when using a different origin. FetchOptions are inherited from Flux UI.
export
webClient : String -> FetchOptions -> Client
webClient base options = MkClient base (requestWith options)
