module Main

import Flux.Auth
import DB.Migration
import Flux.DB.PG
import Data.PGPool
import Config
import Protocol
import System

%default covering

-- Migration 1 is byte-for-byte the existing CRUD application's frozen history.
-- Identity is additive: this milestone never adopts or deletes anonymous tasks.
migrations : List Migration
migrations =
  [ MkMigration 1 "create todos"
      ["CREATE TABLE todos (id BIGSERIAL PRIMARY KEY, title TEXT NOT NULL, done BOOLEAN NOT NULL DEFAULT false)"]
  , MkMigration 2 "accounts and revocable sessions" authSchemaV1
  ]

privateProbe : Principal -> ProbeRequest -> AppProg ProbeResponse
privateProbe p _ = pure (MkProbeResponse p.subjectId)

main : IO ()
main = do
  loaded <- loadConfig
  let cfg = { connectTimeoutMs := Just 5000, readTimeoutMs := Just 5000 } loaded
  args <- getArgs
  let legacy = drop 1 args == ["--legacy-only"]
  Right _ <- runMigrations cfg (if legacy then take 1 migrations else migrations)
    | Left _ => putStrLn "Migration failed" >> exitFailure
  if legacy || drop 1 args == ["--migrate-only"]
    then putStrLn "Migrations applied"
    else do
      Right pool <- newPool defaultPoolConfig cfg | Left _ => exitFailure
      ttl <- getEnv "AUTH_SESSION_TTL_SECONDS"
      Right service <- newAuthService pool (maybe 3600 cast ttl) | Left _ => closePool pool >> exitFailure
      let auth = authRoutes service
      let protected = routes (authenticator service) (MkApi privateProbe (\_ => pure (MkProbeResponse "public")))
      let combined = MkRouter (auth.routes ++ protected.routes)
      let application = app |> withErrorRenderer rpcErrorRenderer |> withRoutes combined
      runProg (runServerArgs (runApp application) (drop 1 args))
      closePool pool
