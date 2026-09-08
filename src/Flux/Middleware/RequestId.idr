module Flux.Middleware.RequestId

import public Flux.Core.HTTP
import public Flux.Core.Middleware
import Flux.Middleware.Internal.Stripe
import Data.Linear.Ref1
import Data.SortedMap
import Data.Fin
import Data.Vect

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

||| A fresh process-local ID generator. Create one at startup and reuse the
||| returned action for the lifetime of the server (see `requestId`, which
||| does this for you).
|||
||| IDs look like `"req-<stripe>-<n>"` rather than a single incrementing
||| `"req-<n>"`: the counter is split into `stripeCount` independent
||| `Data.Linear.Ref1` cells ("stripes"), each incremented via `update` (a
||| lock-free compare-and-swap loop), with a cheap, contention-free random
||| pick (see `Flux.Middleware.Internal.Stripe`) choosing which stripe a
||| given request uses. `n` is still monotonic *within* a stripe, but IDs
||| are no longer globally ordered across stripes.
|||
||| This is not just a `Mutex` swapped for a CAS loop on one shared
||| counter - a single cell, however it's guarded, is still one cache
||| line that every worker thread's concurrent requests all contend for.
||| Under real parallel load that contention itself becomes the
||| bottleneck; spreading updates across independent stripes is what
||| actually lets throughput scale with more worker threads.
export
newIdGenerator : IO (IO String)
newIdGenerator = do
  stripes <- newStripes 0
  pure $ do
    i <- randomStripe
    n <- update (index i stripes) (\n => (S n, n))
    pure ("req-" ++ show (finToNat i) ++ "-" ++ show n)

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
