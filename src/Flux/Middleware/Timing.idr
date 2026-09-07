module Flux.Middleware.Timing

import public Flux.Core.HTTP
import public Flux.Core.Middleware
import public Flux.Server.Logging
import System.Clock
import Data.SortedMap

%default total

export
timingStartKey : String
timingStartKey = "timingStart"

export
responseTimeHeader : String
responseTimeHeader = "X-Response-Time"

-- Current monotonic time in milliseconds
export
getTimeMs : IO Integer
getTimeMs = do
  c <- clockTime Monotonic
  pure (seconds c * 1000 + nanoseconds c `div` 1_000_000)

export
formatDuration : Integer -> String
formatDuration ms =
  if ms < 1 then
    "<1ms"
  else if ms < 1000 then
    show ms ++ "ms"
  else
    show (ms `div` 1000) ++ "." ++ show (ms `mod` 1000) ++ "s"

export
slowRequestThreshold : Integer
slowRequestThreshold = 1000  -- 1 second

export
isSlowRequest : Integer -> Bool
isSlowRequest ms = ms >= slowRequestThreshold

||| Records the request start time in context state. Register with `use`.
export
timing : Middleware
timing ctx = do
  now <- liftIO getTimeMs
  pure (setState timingStartKey (show now) ctx)

elapsedSince : Context -> IO Integer
elapsedSince ctx = do
  now <- getTimeMs
  pure $ case getState timingStartKey ctx of
    Just s  => now - cast s
    Nothing => 0

||| Adds an `X-Response-Time` header from the start time `timing` recorded.
||| Register with `useAfter`, after `timing` has been registered with `use`.
export
responseTime : Middleware
responseTime ctx = do
  elapsed <- liftIO (elapsedSince ctx)
  pure (setHeader responseTimeHeader (formatDuration elapsed) ctx)

||| Logs method, path, status code and duration for every request. Register
||| with `useAfter`, after `timing` has been registered with `use`.
export
requestLog : Logger -> Middleware
requestLog logger ctx = do
  elapsed <- liftIO (elapsedSince ctx)
  liftIO $ logHTTP logger $
    MkHTTPLogContext (show (requestMethod ctx.request)) (requestUri ctx.request) ctx.statusCode elapsed
  pure ctx
