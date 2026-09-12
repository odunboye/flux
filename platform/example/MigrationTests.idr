module MigrationTests

import Flux.DB.Migration
import Data.PGValue
import Idris2_pg
import Config
import Data.IORef
import System

%default covering

check : IORef Nat -> String -> Bool -> IO ()
check failures label True = putStrLn ("PASS " ++ label)
check failures label False = do
  n <- readIORef failures
  writeIORef failures (S n)
  putStrLn ("FAIL " ++ label)

applied : Nat -> Either PGError Nat -> Bool
applied n (Right actual) = n == actual
applied _ _ = False

rejected : Either PGError Nat -> Bool
rejected (Left _) = True
rejected _ = False

one : Migration
one = MkMigration 1 "create probe"
  [ "CREATE TABLE migration_probe (id bigint PRIMARY KEY, title text NOT NULL)"
  , "INSERT INTO migration_probe(id, title) VALUES (1, 'preserved')"
  ]

two : Migration
two = MkMigration 2 "add done"
  ["ALTER TABLE migration_probe ADD COLUMN done boolean NOT NULL DEFAULT false"]

three : Migration
three = MkMigration 3 "second row"
  ["INSERT INTO migration_probe(id, title) VALUES (2, 'second')"]

main : IO ()
main = do
  Just "1" <- getEnv "FLUX_DISPOSABLE_TEST"
    | _ => putStrLn "Refusing migration tests outside a disposable database" >> exitFailure
  cfg <- loadConfig
  failures <- newIORef 0
  fresh <- runMigrations cfg [one]
  check failures "migration fresh install" (applied 1 fresh)
  replay <- runMigrations cfg [one]
  check failures "migration replay is a no-op" (applied 0 replay)
  upgrade <- runMigrations cfg [one, two]
  check failures "migration upgrade applies only pending version" (applied 1 upgrade)
  changed <- runMigrations cfg [{ name := "edited historical migration" } one, two]
  check failures "migration history drift rejected" (rejected changed)
  missing <- runMigrations cfg [one]
  check failures "database ahead of application rejected" (rejected missing)
  failed <- runMigrations cfg [one, two,
    MkMigration 3 "failed change"
      ["INSERT INTO migration_probe(id, title) VALUES (2, 'must roll back')",
       "ALTER TABLE missing_migration_probe ADD COLUMN x integer"]]
  check failures "failed migration reports failure" (rejected failed)
  Right db <- connectDB cfg | Left err => putStrLn (displayError err) >> exitFailure
  Right [row] <- queryRows db "SELECT count(*) AS count, min(title) AS title FROM migration_probe" []
    | _ => closeDB db >> exitFailure
  check failures "failed migration rolls back data and preserves existing rows"
    (columnByName row "count" == Just (Just "1") && columnByName row "title" == Just (Just "preserved"))
  Right [history] <- queryRows db "SELECT count(*) AS count FROM flux_db_meta.migrations" []
    | _ => closeDB db >> exitFailure
  check failures "failed migration does not record its version" (columnByName history "count" == Just (Just "2"))
  Right _ <- queryRows db "SELECT pg_advisory_lock(723946218534101)" []
    | _ => closeDB db >> exitFailure
  locked <- runMigrations cfg [one, two, three]
  check failures "concurrent migration runner fails closed on held lock" (rejected locked)
  closeDB db
  recovered <- runMigrations cfg [one, two, three]
  check failures "migration succeeds after lock release and previous failure" (applied 1 recovered)
  duplicate <- runMigrations cfg [one, one]
  check failures "duplicate migration versions rejected" (rejected duplicate)
  control <- runMigrations cfg [MkMigration 1 "bad" ["COMMIT"]]
  check failures "transaction control rejected" (rejected control)
  multiple <- runMigrations cfg [one, two, three,
    MkMigration 4 "multiple statements" ["INSERT INTO migration_probe(id, title) VALUES (3, 'bad'); COMMIT"]]
  check failures "multiple statements in an entry rejected" (rejected multiple)
  final <- runMigrations cfg [one, two, three]
  check failures "migration history remains usable after invalid SQL" (applied 0 final)
  -- Simulate a populated pre-rename database, including original timestamps.
  Right metadata <- connectDB cfg | Left err => putStrLn (displayError err) >> exitFailure
  Right [atomic] <- queryRows metadata "SELECT count(*) AS count FROM migration_probe" []
    | _ => closeDB metadata >> exitFailure
  check failures "rejected SQL batch executes no statements" (columnByName atomic "count" == Just (Just "2"))
  Right [before] <- queryRows metadata "SELECT md5(string_agg(row_to_json(m)::text, ',' ORDER BY version)) AS digest FROM flux_db_meta.migrations m" []
    | _ => closeDB metadata >> exitFailure
  Right _ <- execCommand metadata "ALTER SCHEMA flux_db_meta RENAME TO nebula_meta" []
    | _ => closeDB metadata >> exitFailure
  legacy <- runMigrations cfg [one, two, three]
  check failures "legacy metadata blocks automatic replay" (rejected legacy)
  Right [absent] <- queryRows metadata "SELECT to_regnamespace('flux_db_meta') IS NULL AS absent" []
    | _ => closeDB metadata >> exitFailure
  check failures "legacy guard does not create a parallel history" (columnByName absent "absent" == Just (Just "t"))
  Right _ <- execCommand metadata "CREATE SCHEMA flux_db_meta" []
    | _ => closeDB metadata >> exitFailure
  ambiguous <- runMigrations cfg [one, two, three]
  check failures "both metadata schemas fail closed" (rejected ambiguous)
  Right _ <- execCommand metadata "DROP SCHEMA flux_db_meta" []
    | _ => closeDB metadata >> exitFailure
  Right _ <- execCommand metadata "ALTER SCHEMA nebula_meta RENAME TO flux_db_meta" []
    | _ => closeDB metadata >> exitFailure
  Right [after] <- queryRows metadata "SELECT md5(string_agg(row_to_json(m)::text, ',' ORDER BY version)) AS digest FROM flux_db_meta.migrations m" []
    | _ => closeDB metadata >> exitFailure
  check failures "metadata cutover preserves every history field" (columnByName before "digest" == columnByName after "digest")
  closeDB metadata
  adopted <- runMigrations cfg [one, two, three]
  check failures "renamed metadata replays no historical SQL" (applied 0 adopted)
  extended <- runMigrations cfg [one, two, three,
    MkMigration 4 "post-rename change" ["INSERT INTO migration_probe(id, title) VALUES (3, 'after; rename');"]]
  case extended of
    Left err => putStrLn (displayError err)
    Right n => putStrLn ("Post-cutover migrations applied: " ++ show n)
  check failures "renamed metadata accepts new migrations" (applied 1 extended)
  count <- readIORef failures
  if count == 0 then putStrLn "All migration checks passed" else exitFailure
