module Flux.Middleware.RequestId

import public Flux.Core.HTTP
import public Flux.Core.Middleware
import Data.IORef
import Data.SortedMap

%default total

export
requestIdHeader : String
requestIdHeader = "X-Request-ID"

export
responseIdHeader : String
responseIdHeader = "X-Request-ID"

export
requestIdKey : String
requestIdKey = "requestId"

||| A fresh process-local, monotonically increasing ID generator. Create one
||| at startup and reuse the returned action for the lifetime of the server
||| (see `requestId`, which does this for you).
export
newIdGenerator : IO (IO String)
newIdGenerator = do
  ref <- newIORef 0
  pure $ do
    n <- readIORef ref
    writeIORef ref (n + 1)
    pure ("req-" ++ show n)

||| Request-ID middleware parameterised over the ID generator: reuses an
||| existing `X-Request-ID` header from the client if present, otherwise
||| generates a fresh one. Either way, the ID ends up on the response header
||| and in context state (see `getRequestId`).
export
requestIdWith : IO String -> Middleware
requestIdWith gen ctx =
  case lookup requestIdHeader ctx.request.headers of
    Just id => pure (setHeader responseIdHeader id (setState requestIdKey id ctx))
    Nothing => do
      id <- liftIO gen
      pure (setHeader responseIdHeader id (setState requestIdKey id ctx))

||| Convenience constructor: builds a request-ID middleware backed by a
||| fresh counter. Call once at startup, e.g. `reqId <- requestId`.
export
requestId : IO Middleware
requestId = requestIdWith <$> newIdGenerator

export
getRequestId : Context -> Maybe String
getRequestId ctx = getState requestIdKey ctx
