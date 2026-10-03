||| The behavioral contract every `TodoRepository` implementation this
||| project ships (`pgTodoRepository`/`inMemoryTodoRepository`) is
||| expected to satisfy - run against BOTH via this SAME function
||| (`test/src/Main.idr`'s real-Postgres scenario and `test/src/
||| InMemoryMain.idr`'s zero-Postgres one), through the SAME
||| `Handlers.ActiveRecord` handlers/`TodoApi.buildApp`, so a divergence
||| between the two implementations shows up as a real test failure
||| instead of two separately-written, silently-drifting-apart
||| assertion sets.
|||
||| Self-contained: starts on an empty table/store, ends on one with
||| only todo 2 ("Write more Idris", done) left - safe to run standalone,
||| no direct `DB` access anywhere in this function (every check goes
||| through `run`/HTTP only, so it works identically against a real
||| `App` or an in-memory one).
|||
||| Deliberately excludes anything Postgres-only - the `BIGINT` range
||| check, `Handlers.TypedQuery` comparison, real-SQL error redaction -
||| those stay in `Main`'s own scenario; the in-memory double was never
||| meant to replicate them (see `InMemoryRepository`'s own doc comment
||| on what `query` shapes it actually supports).
module RepositoryBehavior

import public TestHarness
import Models
import JSON.Simple
import Data.IORef

%default covering

export
covering
repositoryBehaviorChecks : Data.IORef.IORef TestState -> App -> IO ()
repositoryBehaviorChecks st application = do
  let go = check st

  -- list on an empty table
  r1 <- run application (mkRequest GET "/todos")
  go "listTodos: empty table returns 200 []" (r1.status == 200 && r1.body == "[]")

  -- create: invalid body (missing "title")
  r3 <- run application (mkRequestWithBody POST "/todos" "{}")
  go "createTodo: missing title is 400" (r3.status == 400)

  -- create: a real todo (should get id 1 - fresh table)
  r4 <- run application (mkRequestWithBody POST "/todos" #"{"title":"Buy milk"}"#)
  let created = decodeMaybe {a = Todo} r4.body
  go "createTodo: 201, id=1, done=false"
    (r4.status == 201 && created == Just (MkTodo 1 "Buy milk" False))

  -- create a second one, to exercise list/ordering
  r5 <- run application (mkRequestWithBody POST "/todos" #"{"title":"Write Idris code"}"#)
  go "createTodo: second insert gets id=2"
    (r5.status == 201 && decodeMaybe {a = Todo} r5.body == Just (MkTodo 2 "Write Idris code" False))

  -- list again: both, in id order
  r6 <- run application (mkRequest GET "/todos")
  go "listTodos: both todos, ordered by id"
    (r6.status == 200 &&
     decodeMaybe {a = List Todo} r6.body ==
       Just [MkTodo 1 "Buy milk" False, MkTodo 2 "Write Idris code" False])

  -- get by id
  r7 <- run application (mkRequest GET "/todos/1")
  go "getTodo: existing id returns it"
    (r7.status == 200 && decodeMaybe {a = Todo} r7.body == Just (MkTodo 1 "Buy milk" False))

  -- get missing id
  r8 <- run application (mkRequest GET "/todos/999")
  go "getTodo: missing id is 404" (r8.status == 404)

  -- get invalid (non-numeric) id
  r9 <- run application (mkRequest GET "/todos/not-a-number")
  go "getTodo: non-numeric id is 400" (r9.status == 400)

  -- Regression test for the listTodos ORDER BY fix: `repo.crud.query
  -- selectAll` alone (what an earlier version of this handler called)
  -- generates no ORDER BY at all, so Postgres is free to return rows in
  -- a different order after an UPDATE - create a third todo, update the
  -- FIRST of the three, then check the full list is still in id order
  -- (not update-recency order), all before any delete happens. Cleans
  -- up after itself (reverts the update, deletes the third todo) so it
  -- leaves state identical to before it ran - every check after this
  -- one keeps working unmodified.
  r9c <- run application (mkRequestWithBody POST "/todos" #"{"title":"Read a book"}"#)
  go "createTodo: third insert gets id=3"
    (r9c.status == 201 && decodeMaybe {a = Todo} r9c.body == Just (MkTodo 3 "Read a book" False))

  r9d <- run application (mkRequestWithBody PUT "/todos/1" #"{"title":"Buy milk and eggs","done":false}"#)
  go "updateTodo: updating the first of several todos succeeds"
    (r9d.status == 200 && decodeMaybe {a = Todo} r9d.body == Just (MkTodo 1 "Buy milk and eggs" False))

  r9e <- run application (mkRequest GET "/todos")
  go "listTodos: stays ordered by id after updating the first of several, before any delete"
    (r9e.status == 200 &&
     decodeMaybe {a = List Todo} r9e.body ==
       Just [ MkTodo 1 "Buy milk and eggs" False
            , MkTodo 2 "Write Idris code" False
            , MkTodo 3 "Read a book" False
            ])

  _ <- run application (mkRequestWithBody PUT "/todos/1" #"{"title":"Buy milk","done":false}"#)
  _ <- run application (mkRequest DELETE "/todos/3")

  -- toggle
  r10 <- run application (mkRequest POST "/todos/1/toggle")
  go "toggleTodo: flips done to true"
    (r10.status == 200 && decodeMaybe {a = Todo} r10.body == Just (MkTodo 1 "Buy milk" True))

  r11 <- run application (mkRequest POST "/todos/1/toggle")
  go "toggleTodo: flips done back to false"
    (r11.status == 200 && decodeMaybe {a = Todo} r11.body == Just (MkTodo 1 "Buy milk" False))

  -- toggle missing id
  r12 <- run application (mkRequest POST "/todos/999/toggle")
  go "toggleTodo: missing id is 404" (r12.status == 404)

  -- update: full replace
  r13 <- run application
    (mkRequestWithBody PUT "/todos/2" #"{"title":"Write more Idris","done":true}"#)
  go "updateTodo: full replace"
    (r13.status == 200 &&
     decodeMaybe {a = Todo} r13.body == Just (MkTodo 2 "Write more Idris" True))

  -- update: invalid body
  r14 <- run application (mkRequestWithBody PUT "/todos/2" "{}")
  go "updateTodo: invalid body is 400" (r14.status == 400)

  -- update: missing id
  r15 <- run application
    (mkRequestWithBody PUT "/todos/999" #"{"title":"x","done":false}"#)
  go "updateTodo: missing id is 404" (r15.status == 404)

  -- delete
  r16 <- run application (mkRequest DELETE "/todos/1")
  go "deleteTodo: existing id is 204" (r16.status == 204)

  -- delete again: already gone
  r17 <- run application (mkRequest DELETE "/todos/1")
  go "deleteTodo: already-deleted id is 404" (r17.status == 404)

  -- final list: only todo 2 left
  r18 <- run application (mkRequest GET "/todos")
  go "listTodos: reflects the delete"
    (r18.status == 200 &&
     decodeMaybe {a = List Todo} r18.body == Just [MkTodo 2 "Write more Idris" True])
