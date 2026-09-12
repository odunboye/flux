module Flux.Platform.Client.Native

import public Flux.Platform.Client

%default covering

||| Flux UI native curl-backed Task transport. Runtime scheduling and transport
||| limits are those of Flux.UI.Effect.Http, not the server's owned task runtime.
export
nativeClient : String -> Client
nativeClient base = MkClient base Flux.UI.Effect.Http.request
