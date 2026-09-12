module Config


import Flux.DB.PG
import DevPostgres

--------------------------------------------------------------------------------
-- Config
--------------------------------------------------------------------------------

getEnvDef : String -> String -> IO String
getEnvDef name def = pure (fromMaybe def !(getEnv name))

-- Only explicit verified TLS or explicit plaintext is supported. Never treat
-- libpq's weaker prefer/allow/require modes as permission to skip identity.
withTLSFromEnv : String -> String -> PGConfig -> IO PGConfig
withTLSFromEnv modeName caName cfg = do
  mode <- getEnv modeName
  ca <- getEnv caName
  case mode of
    Just "verify-full" => pure ({ useTLS := True, tlsCAFile := ca } cfg)
    Nothing => case ca of
      Nothing => pure cfg
      Just _ => putStrLn (caName ++ " requires " ++ modeName ++ "=verify-full") >> exitFailure
    Just "disable" => case ca of
      Nothing => pure cfg
      Just _ => putStrLn (caName ++ " conflicts with disabled TLS") >> exitFailure
    Just _ => putStrLn (modeName ++ " must be verify-full or disable") >> exitFailure

||| Reads the standard libpq env vars (`PGHOST`/`PGPORT`/`PGUSER`/
||| `PGPASSWORD`/`PGDATABASE`), defaulting to match the `docker run`
||| command in the README (`127.0.0.1:5432`/`testuser`/`testpass`/
||| `testdb`). Used by the real app (`Main`) - NOT by the test suite,
||| which drops and recreates the table it connects to and needs its own
||| separate env-var namespace instead (`loadTestConfig`) precisely so
||| pointing the app at a real database via these vars can never also
||| redirect the test suite there.
export
loadConfig : IO PGConfig
loadConfig = do
  host   <- getEnvDef "PGHOST" "127.0.0.1"
  portS  <- getEnvDef "PGPORT" "5432"
  user   <- getEnvDef "PGUSER" "testuser"
  pass   <- getEnvDef "PGPASSWORD" "testpass"
  dbName <- getEnvDef "PGDATABASE" "testdb"
  withTLSFromEnv "PGSSLMODE" "PGSSLROOTCERT" (mkPGConfig host (cast portS) user pass dbName)

||| Reads dedicated TEST-only env vars (`PG_TEST_HOST`/`PG_TEST_PORT`/
||| `PG_TEST_USER`/`PG_TEST_PASSWORD`/`PG_TEST_DB` - matching flux-postgres's
||| and flux-db's own test suites' convention), completely independent of
||| `loadConfig`'s `PGHOST`/etc. `test/src/Main.idr` drops and recreates
||| the `todos` table against whatever this resolves to, so this
||| deliberately does NOT fall back to `loadConfig` or share its env-var
||| names - a shared namespace would mean pointing the real app at a
||| remote/production database (via `PGHOST`/`PGDATABASE`) also silently
||| redirects the test suite's `DROP TABLE` there the next time it runs
||| in the same shell.
|||
||| The default DATABASE NAME is also deliberately different from
||| `loadConfig`'s own default (`todo_api_test` here, `testdb` there) -
||| not just a different env-var namespace - so running the test suite
||| with NO configuration at all still can't collide with the app's own
||| default target. `ensureTestDatabase` (below) makes sure this
||| database actually exists before anything connects to it.
export
loadTestConfig : IO PGConfig
loadTestConfig = do
  host   <- getEnvDef "PG_TEST_HOST" "127.0.0.1"
  portS  <- getEnvDef "PG_TEST_PORT" "5432"
  user   <- getEnvDef "PG_TEST_USER" "testuser"
  pass   <- getEnvDef "PG_TEST_PASSWORD" "testpass"
  dbName <- getEnvDef "PG_TEST_DB" "todo_api_test"
  withTLSFromEnv "PG_TEST_SSLMODE" "PG_TEST_SSLROOTCERT" (mkPGConfig host (cast portS) user pass dbName)

||| Postgres double-quoted-identifier escaping - doubles any embedded
||| `"` (the one character a quoted identifier needs escaped), so
||| `CREATE DATABASE \{quoteIdent cfg.database}` below is safe
||| regardless of what `cfg.database` actually contains, not just names
||| with no special characters.
quoteIdent : String -> String
quoteIdent s = "\"" ++ pack (concatMap (\c => if c == '"' then ['"', '"'] else [c]) (unpack s)) ++ "\""

||| Postgres's own SQLSTATE for "a database with this name already
||| exists" (class 42, syntax error/access rule violation) - the ONE
||| `CREATE DATABASE` failure `ensureTestDatabase` tolerates.
duplicateDatabaseCode : String
duplicateDatabaseCode = "42P04"

||| The canonical local-dev Postgres identity this project's own
||| `docker run` command (see README) sets up - a FIXED literal, not
||| read from `PGHOST`/etc (unlike `loadConfig`) and not `PG_TEST_*`
||| (unlike `loadTestConfig`). Used ONLY by `ensureTestDatabase`, below,
||| to make sure the shared local container/instance itself is up,
||| before it touches its own separately-configured target database -
||| deliberately independent of BOTH `loadConfig` and `loadTestConfig`,
||| so an app pointed at a remote/unreachable database via `PGHOST` can
||| never block or redirect test provisioning (a real bug in an earlier
||| version of this module, not a hypothetical - `ensureTestDatabase`
||| used to call `loadConfig` for exactly this step), and a test run can
||| never unintentionally contact a real app's remote database just to
||| make sure "some" local Postgres is running.
|||
||| Deliberately shares `loadConfig`'s own DEFAULT values (`testdb`
||| specifically) - not a coincidence: a brand-new container's first-
||| boot `POSTGRES_DB` comes from whatever `PGConfig` `ensureLocalPostgres`
||| is FIRST called with, so provisioning via this fixed identity means
||| the app's own default database still ends up existing automatically
||| (the official Postgres image's own init behavior) even if the test
||| suite happens to run before the app ever does, on a truly fresh
||| environment - without this function ever having to read `PGHOST` to
||| get there.
localDevConfig : PGConfig
localDevConfig = mkPGConfig "127.0.0.1" 5432 "testuser" "testpass" "testdb"

||| Ensures `cfg.database` exists inside the Postgres instance
||| `cfg.host`/`cfg.port`/etc identify, creating it via a throwaway
||| connection to Postgres's own always-present `postgres` maintenance
||| database if it doesn't - `CREATE DATABASE` can't run against a
||| connection to the database being created.
|||
||| Provisions the underlying container/instance itself via
||| `localDevConfig` (above) - a fixed local identity, never `loadConfig`
||| (the real app's config, which might point anywhere) and never `cfg`
||| itself for this step (only for the actual `CREATE DATABASE`, against
||| the "postgres" maintenance database, below) - but ONLY when `cfg`
||| itself targets that EXACT host+port (`DevPostgres.isLocalHost cfg.host`
||| AND `cfg.port == localDevConfig.port`). A `PG_TEST_*` config pointed
||| at a genuinely remote host, OR a different port on `127.0.0.1` (a
||| second local Postgres instance, say) has no reason to ALSO require
||| the unrelated well-known local container to be reachable - checking
||| the host alone isn't enough, since `127.0.0.1` on a non-default port
||| is still "local" but still a different instance entirely. A real bug
||| in an earlier version of this function, not a hypothetical: it
||| called `ensureLocalPostgres localDevConfig` unconditionally, so a
||| perfectly valid remote-or-alternate-port `PG_TEST_*` setup failed
||| outright whenever that unrelated local Postgres wasn't running, even
||| with Docker management otherwise irrelevant. `ensureLocalPostgres
||| localDevConfig` is a no-op once the container already exists (the
||| common local-dev case), so this costs nothing on every run after the
||| first.
|||
||| Only tolerates a "database already exists" failure from `CREATE
||| DATABASE` (Postgres's own `42P04`, the expected case on every run
||| after the first) - any other failure (a permissions error, the
||| instance going unreachable mid-statement) is propagated, not
||| silently swallowed.
export
ensureTestDatabase : PGConfig -> IO (Either PGError ())
ensureTestDatabase cfg = do
  localResult <- if not (isLocalHost cfg.host && cfg.port == localDevConfig.port)
    then pure (Right ())
    else do
      Right localDb <- ensureLocalPostgres localDevConfig
        | Left err => pure (Left err)
      closeDB localDb
      pure (Right ())
  Right () <- pure localResult
    | Left err => pure (Left err)
  Right maintDb <- connectDB ({ database := "postgres" } cfg)
    | Left err => pure (Left err)
  result <- execCommand maintDb "CREATE DATABASE \{quoteIdent cfg.database}" []
  closeDB maintDb
  case result of
    Right _               => pure (Right ())
    Left err@(SqlError e) =>
      if code e == Just duplicateDatabaseCode
         then pure (Right ())
         else pure (Left err)
    Left err              => pure (Left err)
