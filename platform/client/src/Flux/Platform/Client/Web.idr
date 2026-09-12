module Flux.Platform.Client.Web

import public Flux.Platform.Client
import public Iris.Effect.Http.Web

%default covering

||| Iris browser/Capacitor fetch transport with Iris-owned cancellation.
||| An empty base URL uses the current origin. Configure CORS at the server
||| when using a different origin. FetchOptions are inherited from Iris.
export
webClient : String -> FetchOptions -> Client
webClient base options = MkClient base (requestWith options)
