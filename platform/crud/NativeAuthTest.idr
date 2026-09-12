module NativeAuthTest

import Client
import Flux.Platform.Client.Native
import Flux.Platform.Client.Auth as Auth
import System

%default covering

collect : Cmd a -> IO a
collect (Task work) = work
collect (MapCmd f command) = f <$> collect command
collect _ = die "FAIL native command shape"

check : String -> Bool -> IO ()
check label True = putStrLn ("PASS " ++ label)
check label False = die ("FAIL " ++ label)

ok : Cmd (Either RpcError a) -> IO a
ok command = do
  Right value <- collect command | Left _ => die "FAIL native RPC"
  pure value

main : IO ()
main = do
  [_, base] <- getArgs | _ => die "Expected test base URL"
  let publicClient = nativeClient base
  rejected <- collect (listTodos publicClient (MkListTodosRequest Nothing) id)
  check "native unauthenticated tasks rejected" (case rejected of Left (RemoteError 401 _ _) => True; _ => False)
  session <- ok (Auth.login publicClient "generated_client" "Generated client test secret!" id)
  let client = withBearer session.token publicClient
  page <- ok (listTodos client (MkListTodosRequest Nothing) id)
  check "native in-memory bearer reads only account tasks" (length page.todos == 50)
  task <- ok (createTodo client (MkCreateTodoRequest "Native private credentials 🚀") id)
  deleted <- ok (deleteTodo client (MkTodoIdRequest task.id) id)
  check "native authenticated create/delete" deleted.deleted
  _ <- ok (Auth.logout client id)
  revoked <- collect (listTodos client (MkListTodosRequest Nothing) id)
  check "native logout revokes task access" (case revoked of Left (RemoteError 401 _ _) => True; _ => False)
  unsafe <- collect (Auth.login (nativeClient "http://example.com") "generated_client" "Generated client test secret!" id)
  check "native refuses remote plaintext before sending credentials" (case unsafe of Left (TransportFailure _) => True; _ => False)
  injected <- collect (publicClient.send (MkRequest POST (base ++ "/rpc/v1/todos/list")
    [("Authorization", "Bearer credential\nInjected: forbidden")] (Just "{}")) id)
  check "native rejects header injection" (case injected of Left (NetworkError _) => True; _ => False)
