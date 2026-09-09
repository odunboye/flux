module Flux.Server.Health

import public Flux.Core.HTTP
import public Flux.Core.Router
import public Flux.Core.Middleware
import public JSON.Simple
import Flux.Middleware.JSON
import public Data.SortedMap
import Data.List
import Data.String
import System.Clock
import System.File

%default total

-- Health status types
public export
data HealthStatus
  = Healthy
  | Unhealthy
  | Degraded

export
Eq HealthStatus where
  Healthy == Healthy = True
  Unhealthy == Unhealthy = True
  Degraded == Degraded = True
  _ == _ = False

export
Show HealthStatus where
  showPrec _ Healthy = "healthy"
  showPrec _ Unhealthy = "unhealthy"
  showPrec _ Degraded = "degraded"

export
ToJSON HealthStatus where
  toJSON Healthy = JString "healthy"
  toJSON Unhealthy = JString "unhealthy"
  toJSON Degraded = JString "degraded"

-- Health check result
public export
record CheckResult where
  constructor MkCheckResult
  name    : String
  status  : HealthStatus
  message : Maybe String

export
ToJSON CheckResult where
  toJSON (MkCheckResult name status msg) =
    JObject
      [ ("name", toJSON name)
      , ("status", toJSON status)
      , ("message", maybe JNull toJSON msg)
      ]

-- Health status record
public export
record HealthStatusRecord where
  constructor MkHealthStatusRecord
  status      : HealthStatus
  version     : String
  checks      : List CheckResult
  timestamp   : Integer

export
ToJSON HealthStatusRecord where
  toJSON (MkHealthStatusRecord status version checks ts) =
    JObject
      [ ("status", toJSON status)
      , ("version", toJSON version)
      , ("checks", toJSON checks)
      , ("timestamp", toJSON ts)
      ]

-- Health check function type
public export
HealthCheck : Type
HealthCheck = IO CheckResult

-- Health check registry
public export
record HealthRegistry where
  constructor MkHealthRegistry
  checks : List HealthCheck

export
emptyRegistry : HealthRegistry
emptyRegistry = MkHealthRegistry []

-- Add a health check
export
addCheck : HealthCheck -> HealthRegistry -> HealthRegistry
addCheck check (MkHealthRegistry checks) = MkHealthRegistry (check :: checks)

-- Run all health checks
export
runChecks : HealthRegistry -> IO (List CheckResult)
runChecks (MkHealthRegistry checks) = traverse (\c => c) checks

-- Calculate overall status
export
overallStatus : List CheckResult -> HealthStatus
overallStatus [] = Healthy
overallStatus results =
  if any (\r => r.status == Unhealthy) results then
    Unhealthy
  else if any (\r => r.status == Degraded) results then
    Degraded
  else
    Healthy

-- Create health status record by actually running the registered checks
export
mkHealthStatus : HealthRegistry -> String -> IO HealthStatusRecord
mkHealthStatus registry version = do
  checks <- runChecks registry
  let status = overallStatus checks
  now <- seconds <$> clockTime UTC
  pure (MkHealthStatusRecord status version checks now)

-- Health endpoint handler: runs every registered check
export
healthHandler : HealthRegistry -> String -> Handler
healthHandler registry version ctx = do
  status <- liftIO (mkHealthStatus registry version)
  pure (sendJSON status ctx)

-- Liveness probe: the process is up, no checks run
export
livenessHandler : Handler
livenessHandler ctx = pure $ sendJSON (JObject [("status", JString "alive")]) ctx

-- Readiness probe: reflects the actual check results. `sendJSON` alone
-- only sets the body/Content-Type, never the status code (see
-- `Flux.Middleware.JSON`) - a status-code-based readiness checker (the
-- normal kind, e.g. Kubernetes) needs `setStatus 503` here too, or it
-- sees permanent success regardless of what the JSON body says.
export
readinessHandler : HealthRegistry -> String -> Handler
readinessHandler registry version ctx = do
  status <- liftIO (mkHealthStatus registry version)
  let ready = status.status /= Unhealthy
  let ctx' = if ready then ctx else setStatus 503 ctx
  pure $ sendJSON (JObject
    [ ("status", JString (if ready then "ready" else "not ready"))
    , ("version", toJSON version)
    ]) ctx'

-- Startup probe: the process has finished booting
export
startupHandler : Handler
startupHandler ctx = pure $ sendJSON (JObject [("status", JString "started")]) ctx

--------------------------------------------------------------------------------
-- Built-in checks
--------------------------------------------------------------------------------
-- An earlier version of this section had five "standard" checks
-- (database/cache/externalService/memory/disk), all hardcoded
-- placeholders that unconditionally returned Healthy regardless of
-- anything real - a server using registerStandardChecks always reported
-- healthy no matter what, which is worse than not having health checks
-- at all (a monitoring system trusting it wouldn't catch a real outage).
--
-- database/cache/externalService are gone outright: what "healthy"
-- means for a specific database or cache connection is inherently
-- application-specific, and Flux has no database/cache client of its
-- own to check generically - write your own via addCheck, e.g.
-- `addCheck (do ok <- pingMyDb; pure (MkCheckResult "database" (if ok then Healthy else Unhealthy) Nothing)) registry`.
--
-- disk is also gone, but for a different reason: a real implementation
-- exists in principle (statvfs, POSIX, both platforms) via
-- System.Posix.File.Stats in this project's own dependency tree - but
-- as shipped there, every Statvfs/FileStats field accessor is linked
-- against the wrong library (`linux-idris` instead of `posix-idris`,
-- where the C symbols actually live), and Flux doesn't depend on the
-- `linux` package at all (nor could it - linux.c doesn't compile on
-- Darwin). Calling it would fail at runtime with a missing-symbol
-- error, on both platforms, as currently shipped upstream. Working
-- around it means reimplementing the struct-marshaling FFI code
-- from scratch (raw pointer/struct layout, real memory-safety risk if
-- gotten wrong) - not attempted here; write your own if you need it,
-- or fix it upstream.
--
-- memory is real: it reads the process's own RSS from
-- /proc/self/status, the same way Flux.Middleware.Internal.Random reads
-- /dev/urandom - plain file IO, no FFI. Only available on Linux (/proc
-- doesn't exist on Darwin) - reports Degraded, not a false Healthy,
-- anywhere it can't get a real answer, whether that's the platform or
-- an unexpected /proc/self/status format.

-- Extracts the "VmRSS:" line's kB figure from /proc/self/status's
-- contents, e.g. "VmRSS:\t   12345 kB" -> Just 12345. Exported for
-- direct unit testing (test/src/TestHealth.idr) - the one piece of
-- this check's logic that doesn't depend on the host actually having
-- /proc, or on real RSS content.
export
parseVmRSSKb : String -> Maybe Integer
parseVmRSSKb contents =
  case find (isPrefixOf "VmRSS:") (lines contents) of
    Nothing   => Nothing
    Just line =>
      case filter isDigit (unpack line) of
        [] => Nothing
        ds => Just (cast (pack ds))

||| Checks the process's own resident memory (RSS) against `thresholdMB`
||| - Linux only (reads /proc/self/status; reports Degraded rather than
||| a false Healthy anywhere else, including on Darwin, where /proc
||| doesn't exist at all - see this section's doc comment above).
export covering
memoryCheck : (thresholdMB : Integer) -> IO CheckResult
memoryCheck thresholdMB = do
  Right contents <- readFile "/proc/self/status"
    | Left _ => pure (MkCheckResult "memory" Degraded (Just "unsupported on this platform (no /proc/self/status)"))
  case parseVmRSSKb contents of
    Nothing    => pure (MkCheckResult "memory" Degraded (Just "could not parse /proc/self/status"))
    Just rssKb =>
      let rssMB := rssKb `div` 1024
       in pure $ if rssMB > thresholdMB
            then MkCheckResult "memory" Unhealthy (Just "RSS \{show rssMB}MB exceeds threshold \{show thresholdMB}MB")
            else MkCheckResult "memory" Healthy (Just "RSS \{show rssMB}MB")

-- Register the standard health/liveness/readiness/startup routes
export
healthRoutes : HealthRegistry -> String -> Router Handler -> Router Handler
healthRoutes registry version router =
  get "/health" (healthHandler registry version) $
  get "/healthz" (healthHandler registry version) $
  get "/ready" (readinessHandler registry version) $
  get "/live" livenessHandler $
  get "/startup" startupHandler router
