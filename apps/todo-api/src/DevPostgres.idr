||| Thin, Postgres-specific glue over `flux-docker`'s general
||| container-management API: makes sure a local Postgres container is
||| up before connecting, rather than requiring a manual `docker run`
||| step.
|||
||| `ensureLocalPostgres` is a strict superset of plain `connectDB` -
||| every Docker step here is advisory, and on any skip/failure path
||| this degrades to exactly `connectDB cfg`'s existing behavior. It is
||| never a new way for the app to fail that `connectDB` alone didn't
||| already have.
module DevPostgres

import Docker
import Idris2_pg
import Data.PGTypes
import Data.Maybe
import System

%default covering

skipEnvVar : String
skipEnvVar = "TODO_API_SKIP_DOCKER"

containerNameEnv : String
containerNameEnv = "TODO_API_PG_CONTAINER"

defaultContainerName : String
defaultContainerName = "todo-api-pg"

pgImage : String
pgImage = "postgres:16"

||| Whether `h` names a loopback host - `shouldManageDocker`'s own
||| criterion for whether Docker management is even in-scope for a given
||| config. Exported so other local-Postgres-provisioning logic (see
||| `Config.ensureTestDatabase`) can apply the exact same "is this even
||| a local target" check against a config of its own, rather than
||| unconditionally assuming every caller means a local database.
export
isLocalHost : String -> Bool
isLocalHost h = h == "127.0.0.1" || h == "localhost"

getEnvDef : String -> String -> IO String
getEnvDef name def = pure (fromMaybe def !(getEnv name))

containerName : IO String
containerName = getEnvDef containerNameEnv defaultContainerName

pgContainerSpec : String -> PGConfig -> ContainerSpec
pgContainerSpec name cfg = MkContainerSpec name pgImage
  [ ("POSTGRES_USER", cfg.user)
  , ("POSTGRES_PASSWORD", cfg.password)
  , ("POSTGRES_DB", cfg.database)
  ]
  [(cast cfg.port, 5432)]

warnIfPortMismatch : String -> PGConfig -> IO ()
warnIfPortMismatch name cfg = do
  mport <- publishedPort name 5432
  case mport of
    Just p  => when (p /= cast cfg.port) $
      putStrLn "warning: container \"\{name}\" is publishing 5432 on port \{show p}, but PGPORT is \{show cfg.port} - probably a stale container from an old config"
    Nothing => pure ()

manageContainer : PGConfig -> IO ()
manageContainer cfg = do
  name <- containerName
  case !(inspect name) of
    NotFound => do
      putStrLn "Starting local Postgres container \"\{name}\" (\{pgImage}) ..."
      Left code <- run (pgContainerSpec name cfg)
        | Right () => pure ()
      putStrLn "docker run exited with code \{show code} - see Docker's own error above, if any"
    Stopped  => do
      putStrLn "Local Postgres container \"\{name}\" exists but is stopped - starting it ..."
      Left code <- start name
        | Right () => pure ()
      putStrLn "docker start exited with code \{show code} - see Docker's own error above, if any"
    Running  => warnIfPortMismatch name cfg

-- Bounded retry against the real thing that matters (a real connectDB),
-- not pg_isready/log-scraping - this is exactly the readiness check
-- flux-docker's own README says stays out of its scope. Returns the
-- successful connection directly rather than a separate probe-then-
-- reconnect dance, since there's no separate "probe config" involved -
-- see below for why.
--
-- Deliberately does NOT use `connectTimeoutMs` to bound each attempt -
-- confirmed directly (not assumed) that flux-postgres's timeout-racing
-- mechanism (`Network.Timeout`, `withConnectTimeout`) does not
-- correctly recognize a connection that completes successfully within
-- the window: setting `connectTimeoutMs` to 2000 *or* 5000 against a
-- Postgres container that a genuinely unbounded `connectDB` connects to
-- in ~2.2s made *every single attempt* fail with "connection timed
-- out", exhausting the whole retry budget every time regardless of the
-- bound chosen (confirmed via timestamped tracing: each attempt ran for
-- exactly its configured timeout, then failed) - not "my timeout was
-- too short", a real bug in that racing mechanism itself.
--
-- This is NOT a safe substitute, though, and each attempt below (and
-- `connectDB` calls elsewhere in this app) remains genuinely unbounded -
-- a real, currently-unresolved gap, not one this comment should claim
-- away. `connectDB` is more than the TCP handshake: "nothing listening
-- yet" does fail fast at the OS level, but a process that DOES accept
-- the TCP connection and then stalls partway through the Postgres
-- startup/auth handshake (a wedged container, an overloaded/locked
-- server) would hang this call indefinitely - there is no bound on that
-- once the racing mechanism above can't be trusted. Fixing this
-- properly means fixing `Network.Timeout`'s racing bug itself, in
-- flux-postgres - out of scope for this app-level retry loop; not attempted
-- here.
waitUntilReady : PGConfig -> IO (Either PGError DB)
waitUntilReady cfg = go 10
  where
    go : Nat -> IO (Either PGError DB)
    go 0     = connectDB cfg
    go (S n) = case !(connectDB cfg) of
      Right db => pure (Right db)
      Left _   => do sleep 1; go n

shouldManageDocker : PGConfig -> IO Bool
shouldManageDocker cfg =
  if not (isLocalHost cfg.host) then pure False
  else do
    skip <- getEnvDef skipEnvVar "0"
    if skip == "1" then pure False else available

export
covering
ensureLocalPostgres : PGConfig -> IO (Either PGError DB)
ensureLocalPostgres cfg = do
  manage <- shouldManageDocker cfg
  if manage
     then do
       manageContainer cfg
       waitUntilReady cfg
     else connectDB cfg
