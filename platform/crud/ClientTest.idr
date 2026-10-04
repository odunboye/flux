module ClientTest

import Client
import Iris.Client.Web
import Iris.Client.Auth as Auth
import Data.IORef
import Data.List

%default covering

%foreign "javascript:lambda: _w => globalThis.__rpcTestBase || ''"
prim_base : PrimIO String

%foreign "javascript:lambda: (ok,_w) => { if(globalThis.__rpcTestResult!==0)globalThis.__rpcTestResult=ok; if(typeof process!=='undefined')process.exitCode=globalThis.__rpcTestResult===1?0:1; }"
prim_done : Int -> PrimIO ()

fail : String -> IO ()
fail label = putStrLn ("FAIL " ++ label) >> primIO (prim_done 0)

check : String -> Bool -> IO ()
check label True = putStrLn ("PASS " ++ label)
check label False = fail label

execute : Cmd msg -> (msg -> IO ()) -> IO ()
execute (CancellableTask action) send = do
  _ <- action send
  pure ()
execute (Task action) send = action >>= send
execute (MapCmd f command) send = execute command (send . f)
execute _ _ = fail "unexpected Iris command shape"

run : Cmd (Either RpcError a) -> (a -> IO ()) -> IO ()
run command next = execute command $ \result => case result of
  Right value => next value
  Left (RemoteError status code message) => fail ("unexpected RPC error " ++ show status ++ " " ++ code ++ " " ++ message)
  Left (InvalidResponse reason) => fail reason
  Left _ => fail "unexpected transport failure"

reject : Cmd (Either RpcError a) -> IO () -> IO ()
reject command next = execute command $ \result => do
  check "invalid request remains a typed error"
    (case result of Left (RemoteError 400 "invalid_request" _) => True; _ => False)
  next

same : TodoView -> FindTodoResponse -> Bool
same expected actual = case actual.todo of
  Nothing => False
  Just todo => todo.id == expected.id && todo.title == expected.title && todo.done == expected.done

missing : FindTodoResponse -> Bool
missing response = case response.todo of Nothing => True; _ => False

-- Bounded recursion also makes a repeated/stuck cursor a test failure.
readPages : Client -> Nat -> Maybe String -> List TodoView -> (List TodoView -> IO ()) -> IO ()
readPages _ Z _ _ _ = fail "pagination did not terminate"
readPages client (S fuel) cursor collected done =
  run (listTodos client (MkListTodosRequest cursor) id) $ \page => do
    check "page is bounded to 50 rows" (length page.todos <= 50)
    case page.nextId of
      Nothing => done (collected ++ page.todos)
      Just next => do
        check "non-final page is full and advances cursor"
          (length page.todos == 50 && Just next /= cursor &&
           map (\todo => todo.id) (head' (reverse page.todos)) == Just next)
        readPages client fuel (Just next) (collected ++ page.todos) done

invalidIds : Client -> List String -> IO () -> IO ()
invalidIds _ [] done = done
invalidIds client (bad :: rest) done =
  reject (getTodo client (MkTodoIdRequest bad) id) (invalidIds client rest done)

lifecycle : Client -> Nat -> IO () -> IO ()
lifecycle client index done =
  run (createTodo client (MkCreateTodoRequest ("Iris CRUD " ++ show index ++ " 🚀")) id) $ \created => do
    check "created exact positive BIGINT"
      ((the Integer (cast created.id)) > 9007199254740991 && not created.done)
    run (getTodo client (MkTodoIdRequest created.id) id) $ \found => do
      check "get returns created record" (same created found)
      let updated = MkTodoView True created.id (created.title ++ " updated")
      run (updateTodo client (MkUpdateTodoRequest True created.id updated.title) id) $ \changed => do
        check "update returns updated record" (same updated changed)
        run (toggleTodo client (MkTodoIdRequest created.id) id) $ \toggled => do
          check "toggle flips updated state" (same ({ done := False } updated) toggled)
          run (deleteTodo client (MkTodoIdRequest created.id) id) $ \deleted => do
            check "delete confirms removal" deleted.deleted
            run (getTodo client (MkTodoIdRequest created.id) id) $ \gone => do
              check "get after delete returns null" (missing gone)
              run (deleteTodo client (MkTodoIdRequest created.id) id) $ \again => do
                check "repeated delete returns false" (not again.deleted)
                done

main : IO ()
main = do
  base <- primIO prim_base
  let client = webClient base (MkFetchOptions 10000 65536)
  check "nullable object accepts explicit null"
    (case decodeMaybe {a = FindTodoResponse} "{\"todo\":null}" of Just value => missing value; _ => False)
  check "nullable field still requires its key"
    (case decodeMaybe {a = ListTodosRequest} "{}" of Nothing => True; _ => False)
  check "list decoder rejects invalid nested record"
    (case decodeMaybe {a = ListTodosResponse} "{\"nextId\":null,\"todos\":[{\"id\":42,\"title\":\"x\",\"done\":false}]}" of Nothing => True; _ => False)
  check "list decoder rejects non-array field"
    (case decodeMaybe {a = ListTodosResponse} "{\"nextId\":null,\"todos\":{}}" of Nothing => True; _ => False)
  check "nullable request encodes explicit null" (encode (MkListTodosRequest Nothing) == "{\"afterId\":null}")
  run (Auth.login client "generated_client" "Generated client test secret!" id) $ \session =>
    checkClient (withBearer session.token client)
  where
  checkClient : Client -> IO ()
  checkClient client = readPages client 4 Nothing [] $ \todos => do
    let ids = map (\todo => todo.id) todos
    check "pagination covers 55 seeds without duplicates or omissions"
      (length ids == 55 && length (nub ids) == 55 &&
       ids == map (\n => show (9223372036854775000 + n)) (the (List Integer) [0..54]))
    let absent = MkTodoIdRequest "9223372036854775807"
    run (getTodo client absent id) $ \found => do
      check "missing get is nullable" (missing found)
      run (toggleTodo client absent id) $ \toggled => do
        check "missing toggle is nullable" (missing toggled)
        run (updateTodo client (MkUpdateTodoRequest False absent.id "missing") id) $ \changed => do
          check "missing update is nullable" (missing changed)
          run (deleteTodo client absent id) $ \deleted => do
            check "missing delete is false" (not deleted.deleted)
            invalidIds client ["", "0", "-1", "01", "1.0", " 1", "1 ", "9223372036854775808", "1 OR 1=1"] $
              reject (listTodos client (MkListTodosRequest (Just "01")) id) $
              reject (client.send (MkRequest POST (client.baseUrl ++ "/rpc/v1/todos/list")
                [("Content-Type", "application/json")] (Just "{}"))
                (decodeResponse {response = ListTodosResponse})) $
              reject (createTodo client (MkCreateTodoRequest "") id) $
                reject (createTodo client (MkCreateTodoRequest (pack (replicate 129 'x'))) id) $ do
                  remaining <- newIORef (the Nat 24)
                  traverse_ (\index => lifecycle client index $ do
                    n <- readIORef remaining
                    writeIORef remaining (n `minus` 1)
                    case n of
                      1 => readPages client 4 Nothing [] $ \after => do
                        check "concurrent CRUD leaves seed data intact" (map (\todo => todo.id) after == ids)
                        putStrLn "PASS 24 concurrent complete Iris CRUD lifecycles"
                        primIO (prim_done 1)
                      _ => pure ()) (the (List Nat) [0..23])
