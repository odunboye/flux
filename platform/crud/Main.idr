module Main

import Protocol
import Config
import Models
import TodoRepository
import Flux.DB.Repository
import Flux.DB.Query
import Flux.DB.Field
import Flux.DB.Migration
import Flux.DB.PG
import Flux.DB.Pool
import System

%default covering

wireTodo : Todo -> TodoView
wireTodo todo = MkTodoView todo.done (show todo.id) todo.title

requireId : String -> AppProg Integer
requireId raw =
  let number : Integer = cast raw in
    if number < 1 || number > 9223372036854775807 || show number /= raw
      then throw (MkAppError 400 "Expected a canonical positive BIGINT identifier")
      else pure number

requireTitle : String -> AppProg ()
requireTitle title =
  if title == "" || length title > 128
    then throw (MkAppError 400 "Title must contain 1 to 128 characters")
    else pure ()

createTodo : TodoRepository -> CreateTodoRequest -> AppProg TodoView
createTodo repo request = do
  requireTitle request.title
  map wireTodo (dbIO (repo.crud.insert (MkNewTodo request.title False)))

getTodo : TodoRepository -> TodoIdRequest -> AppProg FindTodoResponse
getTodo repo request = do
  tid <- requireId request.id
  todo <- dbIO (repo.crud.findById tid)
  pure (MkFindTodoResponse (map wireTodo todo))

updateTodo : TodoRepository -> UpdateTodoRequest -> AppProg FindTodoResponse
updateTodo repo request = do
  tid <- requireId request.id
  requireTitle request.title
  todo <- dbIO (repo.crud.update (MkTodo tid request.title request.done))
  pure (MkFindTodoResponse (map wireTodo todo))

toggleTodo : TodoRepository -> TodoIdRequest -> AppProg FindTodoResponse
toggleTodo repo request = do
  tid <- requireId request.id
  todo <- dbIO (repo.toggle tid)
  pure (MkFindTodoResponse (map wireTodo todo))

deleteTodo : TodoRepository -> TodoIdRequest -> AppProg DeleteTodoResponse
deleteTodo repo request = do
  tid <- requireId request.id
  deleted <- dbIO (repo.crud.deleteById tid)
  pure (MkDeleteTodoResponse deleted)

-- Keyset pagination: bounded 50-row pages plus one lookahead row. The next
-- cursor is the last RETURNED ID, never the lookahead row's ID.
listTodos : TodoRepository -> ListTodosRequest -> AppProg ListTodosResponse
listTodos repo request = do
  after <- case request.afterId of
    Nothing => pure (the Integer 0)
    Just raw => requireId raw
  todos <- dbIO (repo.crud.query
    (selectAll |> where_ (todoColumns.id >. after) |> orderByAsc todoColumns.id |> limit 51))
  let page = take 50 todos
  let next = if length todos > 50 then map (\todo => show todo.id) (head' (reverse page)) else Nothing
  pure (MkListTodosResponse next (map wireTodo page))

-- Frozen reviewed SQL, not a mutable model-derived CREATE statement.
migrations : List Migration
migrations = [MkMigration 1 "create todos"
  ["CREATE TABLE todos (id BIGSERIAL PRIMARY KEY, title TEXT NOT NULL, done BOOLEAN NOT NULL DEFAULT false)"]]

main : IO ()
main = do
  loaded <- loadConfig
  let cfg = { connectTimeoutMs := Just 5000, readTimeoutMs := Just 30000 } loaded
  Right _ <- runMigrations cfg migrations
    | Left err => putStrLn (displayError err) >> exitFailure
  args <- getArgs
  if drop 1 args == ["--migrate-only"]
    then putStrLn "Migrations applied."
    else do
      Right pool <- newPool defaultPoolConfig cfg
        | Left err => putStrLn (displayError err) >> exitFailure
      let repo = pooledTodoRepository pool
      let api = MkApi (createTodo repo) (deleteTodo repo) (getTodo repo)
                      (listTodos repo) (toggleTodo repo) (updateTodo repo)
      let application = app |> useAlways corsAllowAll |> withErrorRenderer rpcErrorRenderer
                            |> withRoutes (routes api)
      runProg (runServerArgs (runApp application) (drop 1 args))
      closePool pool
