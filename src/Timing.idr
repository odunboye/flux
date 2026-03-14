module Timing

import public Middleware
import public HTTP
import public Logging
import Data.SortedMap

%default total

-- Timing context key
export
timingStartKey : String
timingStartKey = "timingStart"

-- Response time header
export
responseTimeHeader : String
responseTimeHeader = "X-Response-Time"

-- Get current time in milliseconds
export
getTimeMs : IO Integer
getTimeMs = pure 0  -- Placeholder - would use actual time in production

-- Timing middleware
-- Records request start time and adds response time header
export
timing : Middleware
timing ctx =
  -- Note: Can't get actual time in pure middleware
  -- This is a simplified version
  -- In production, would need to restructure to allow IO
  setState timingStartKey "0" ctx

-- Timing middleware with logger
export
timingWithLog : Logger -> Middleware
timingWithLog logger ctx =
  -- Log request start
  -- In production, would record actual timestamp
  ctx

-- Response time middleware (runs after handler)
-- Adds X-Response-Time header
export
responseTime : Integer -> Middleware
responseTime elapsedMs ctx =
  setHeader responseTimeHeader (show elapsedMs ++ "ms") ctx

-- Format duration for logging
export
formatDuration : Integer -> String
formatDuration ms =
  if ms < 1 then
    "<1ms"
  else if ms < 1000 then
    show ms ++ "ms"
  else
    show (ms `div` 1000) ++ "." ++ show (ms `mod` 1000) ++ "s"

-- Log slow requests
export
slowRequestThreshold : Integer
slowRequestThreshold = 1000  -- 1 second

-- Check if request is slow
export
isSlowRequest : Integer -> Bool
isSlowRequest ms = ms >= slowRequestThreshold

-- Timing context record
public export
record TimingContext where
  constructor MkTimingContext
  startTime  : Integer
  method     : String
  path       : String

-- Create timing context
export
mkTimingContext : Context -> IO TimingContext
mkTimingContext ctx = do
  startTime <- getTimeMs
  let req = ctx.request
  pure (MkTimingContext startTime (show (requestMethod req)) (requestUri req))

-- Calculate elapsed time
export
elapsed : TimingContext -> IO Integer
elapsed tc = do
  now <- getTimeMs
  pure (now - tc.startTime)

-- Log request timing
export
logRequestTiming : Logger -> TimingContext -> Integer -> IO ()
logRequestTiming logger tc elapsedMs =
  let level = if isSlowRequest elapsedMs then Warn else Info
      msg = "\{tc.method} \{tc.path} completed in \{formatDuration elapsedMs}"
   in log logger (MkLogEntry level "Timing" msg)
