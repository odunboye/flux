module Flux.Server.Health

import public Flux.Core.HTTP
import public Flux.Core.Router
import public Flux.Core.Middleware
import public Flux.Data.JSON
import public Data.SortedMap

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
    JObject (fromList [
      ("name", toJSON name),
      ("status", toJSON status),
      ("message", maybe JNull toJSON msg)
    ])

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
    JObject (fromList [
      ("status", toJSON status),
      ("version", toJSON version),
      ("checks", toJSON checks),
      ("timestamp", toJSON ts)
    ])

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
  pure (MkHealthStatusRecord status version checks 0)

-- Health endpoint handler: runs every registered check
export
healthHandler : HealthRegistry -> String -> Handler
healthHandler registry version ctx = do
  status <- liftIO (mkHealthStatus registry version)
  pure (sendJSON status ctx)

-- Liveness probe: the process is up, no checks run
export
livenessHandler : Handler
livenessHandler ctx = pure $ sendJSON (JObject (fromList [("status", JString "alive")])) ctx

-- Readiness probe: reflects the actual check results
export
readinessHandler : HealthRegistry -> String -> Handler
readinessHandler registry version ctx = do
  status <- liftIO (mkHealthStatus registry version)
  let ready = status.status /= Unhealthy
  pure $ sendJSON (JObject (fromList
    [ ("status", JString (if ready then "ready" else "not ready"))
    , ("version", toJSON version)
    ])) ctx

-- Startup probe: the process has finished booting
export
startupHandler : Handler
startupHandler ctx = pure $ sendJSON (JObject (fromList [("status", JString "started")])) ctx

-- Common health checks

-- Database connection check
export
databaseCheck : IO CheckResult
databaseCheck = do
  -- Placeholder - would check actual DB connection
  pure (MkCheckResult "database" Healthy (Just "Connected"))

-- Cache connection check
export
cacheCheck : IO CheckResult
cacheCheck = do
  -- Placeholder - would check actual cache connection
  pure (MkCheckResult "cache" Healthy (Just "Connected"))

-- External service check
export
externalServiceCheck : String -> IO CheckResult
externalServiceCheck name = do
  -- Placeholder - would check actual service
  pure (MkCheckResult name Healthy Nothing)

-- Memory check
export
memoryCheck : Integer -> IO CheckResult  -- threshold in MB
memoryCheck threshold = do
  -- Placeholder - would check actual memory
  pure (MkCheckResult "memory" Healthy Nothing)

-- Disk check
export
diskCheck : Integer -> IO CheckResult  -- threshold percentage
diskCheck threshold = do
  -- Placeholder - would check actual disk usage
  pure (MkCheckResult "disk" Healthy Nothing)

-- Register standard health checks
export
registerStandardChecks : HealthRegistry -> HealthRegistry
registerStandardChecks registry =
  addCheck databaseCheck $
  addCheck cacheCheck $
  addCheck (memoryCheck 1024) $
  addCheck (diskCheck 90) registry

-- Register the standard health/liveness/readiness/startup routes
export
healthRoutes : HealthRegistry -> String -> Router Handler -> Router Handler
healthRoutes registry version router =
  get "/health" (healthHandler registry version) $
  get "/healthz" (healthHandler registry version) $
  get "/ready" (readinessHandler registry version) $
  get "/live" livenessHandler $
  get "/startup" startupHandler router
