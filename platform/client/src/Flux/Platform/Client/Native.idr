module Flux.Platform.Client.Native

import public Flux.Platform.Client

%default covering

||| Iris native curl-backed Task transport. Runtime scheduling and transport
||| limits are those of Iris.Effect.Http, not the server's owned task runtime.
export
nativeClient : String -> Client
nativeClient base = MkClient base Iris.Effect.Http.request
