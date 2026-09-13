module Main

import Protocol
import Flux.Auth
import Flux.Server.Assets
import Config
import Flux.DB.Migration
import Flux.DB.PG
import Data.PGPool
import Data.PGValue
import System

%default covering

requireId : String -> AppProg String
requireId raw =
  let number : Integer = cast raw in
    if number < 1 || number > 9223372036854775807 || show number /= raw
      then throw (MkAppError 400 "Expected a canonical positive BIGINT identifier")
      else pure raw

requireTitle : String -> AppProg ()
requireTitle title =
  if title == "" || length title > 128
    then throw (MkAppError 400 "Title must contain 1 to 128 characters")
    else pure ()

-- Do not log raw PG errors: their detail may contain private task content.
rows : Pool -> String -> List (Maybe String) -> AppProg (List Row)
rows pool sql params = do
  Right result <- blocking (withConnectionIO pool (\db => queryRows db sql params))
    | Left _ => throw (MkAppError 503 "Task storage unavailable")
  Right value <- pure result | Left _ => throw (MkAppError 500 "Task storage unavailable")
  pure value

wire : Row -> AppProg TodoView
wire row = do
  Just (Just tid) <- pure (columnByName row "id") | _ => throw (MkAppError 500 "Task storage unavailable")
  Just (Just title) <- pure (columnByName row "title") | _ => throw (MkAppError 500 "Task storage unavailable")
  Just (Just done) <- pure (columnByName row "done") | _ => throw (MkAppError 500 "Task storage unavailable")
  unless (done == "t" || done == "f") (throw (MkAppError 500 "Task storage unavailable"))
  pure (MkTodoView (done == "t") tid title)

found : List Row -> AppProg FindTodoResponse
found [] = pure (MkFindTodoResponse Nothing)
found [row] = MkFindTodoResponse . Just <$> wire row
found _ = throw (MkAppError 500 "Task storage unavailable")

createTodo : Pool -> Principal -> CreateTodoRequest -> AppProg TodoView
createTodo pool principal request = do
  requireTitle request.title
  [row] <- rows pool "INSERT INTO private_todos (owner_id,title) VALUES ($1,$2) RETURNING id,title,done" [Just principal.subjectId, Just request.title]
    | _ => throw (MkAppError 500 "Task storage unavailable")
  wire row

getTodo : Pool -> Principal -> TodoIdRequest -> AppProg FindTodoResponse
getTodo pool principal request = do
  tid <- requireId request.id
  rows pool "SELECT id,title,done FROM private_todos WHERE owner_id=$1 AND id=$2" [Just principal.subjectId, Just tid] >>= found

updateTodo : Pool -> Principal -> UpdateTodoRequest -> AppProg FindTodoResponse
updateTodo pool principal request = do
  tid <- requireId request.id
  requireTitle request.title
  rows pool "UPDATE private_todos SET title=$3,done=$4 WHERE owner_id=$1 AND id=$2 RETURNING id,title,done"
    [Just principal.subjectId, Just tid, Just request.title, Just (if request.done then "true" else "false")] >>= found

toggleTodo : Pool -> Principal -> TodoIdRequest -> AppProg FindTodoResponse
toggleTodo pool principal request = do
  tid <- requireId request.id
  rows pool "UPDATE private_todos SET done=NOT done WHERE owner_id=$1 AND id=$2 RETURNING id,title,done"
    [Just principal.subjectId, Just tid] >>= found

deleteTodo : Pool -> Principal -> TodoIdRequest -> AppProg DeleteTodoResponse
deleteTodo pool principal request = do
  tid <- requireId request.id
  deleted <- rows pool "DELETE FROM private_todos WHERE owner_id=$1 AND id=$2 RETURNING id" [Just principal.subjectId, Just tid]
  pure (MkDeleteTodoResponse (not (null deleted)))

listTodos : Pool -> Principal -> ListTodosRequest -> AppProg ListTodosResponse
listTodos pool principal request = do
  after <- case request.afterId of Nothing => pure "0"; Just raw => requireId raw
  result <- rows pool "SELECT id,title,done FROM private_todos WHERE owner_id=$1 AND id>$2 ORDER BY id LIMIT 51"
    [Just principal.subjectId, Just after]
  todos <- traverse wire result
  let page = take 50 todos
  let next = if length todos > 50 then map (.id) (head' (reverse page)) else Nothing
  pure (MkListTodosResponse next page)

-- Versions 1 and 2 are frozen. Old binaries cannot query the new private table.
-- Anonymous rows are archived without adoption, deletion, or an HTTP read path.
migrations : List Migration
migrations = [MkMigration 1 "create todos"
  ["CREATE TABLE todos (id BIGSERIAL PRIMARY KEY, title TEXT NOT NULL, done BOOLEAN NOT NULL DEFAULT false)"],
  MkMigration 2 "accounts and revocable sessions" authSchemaV1,
  MkMigration 3 "private task ownership and anonymous archive"
  ["ALTER TABLE todos RENAME TO todos_anonymous_archive",
   "CREATE TABLE private_todos (id BIGSERIAL PRIMARY KEY, owner_id BIGINT NOT NULL REFERENCES flux_auth_accounts(id), title TEXT NOT NULL CHECK (char_length(title) BETWEEN 1 AND 128), done BOOLEAN NOT NULL DEFAULT false)",
   "CREATE INDEX private_todos_owner_page ON private_todos (owner_id,id)"]]

main : IO ()
main = do
  loaded <- loadConfig
  let cfg = { connectTimeoutMs := Just 5000, readTimeoutMs := Just 30000 } loaded
  Right _ <- runMigrations cfg migrations
    | Left _ => putStrLn "Migration failed; inspect the database with the reviewed migration guide." >> exitFailure
  args <- getArgs
  if drop 1 args == ["--migrate-only"]
    then putStrLn "Migrations applied."
    else do
      Right pool <- newPool defaultPoolConfig cfg | Left _ => exitFailure
      Right identity <- newAuthService pool 86400
        | Left _ => closePool pool >> putStrLn "Authentication initialization failed" >> exitFailure
      let api = MkApi (createTodo pool) (deleteTodo pool) (getTodo pool)
                      (listTodos pool) (toggleTodo pool) (updateTodo pool)
      let todos = routes (authenticator identity) api
      let accounts = authRoutes identity
      assets <- webAssetsFromEnv
      let application = app |> withErrorRenderer rpcErrorRenderer
                            |> withRoutes (MkRouter (accounts.routes ++ todos.routes ++ assets.routes))
      runProg (runServerArgs (runApp application) (drop 1 args))
      closePool pool
