module ClientChecks

import public Client
import Data.IORef
import Data.List

%default covering

public export
check : Data.IORef.IORef Nat -> String -> Bool -> IO ()
check failures label valid = do
  putStrLn ((if valid then "PASS " else "FAIL ") ++ label)
  if valid then pure () else do
    n <- readIORef failures
    writeIORef failures (S n)

-- Minimal test dispatcher; production apps hand Cmds to the Iris runtime.
-- Returns the cancellation action instead of stripping CancellableTask.
public export
execute : Cmd msg -> (msg -> IO ()) -> IO (IO ())
execute (Task action) send = action >>= send >> pure (pure ())
execute (CancellableTask action) send = action send
execute (StreamTask action) send = action send >> pure (pure ())
execute (MapCmd f command) send = execute command (send . f)
execute (Batch commands) send = do
  cancels <- traverse (\command => execute command send) commands
  pure (sequence_ cancels)
execute _ _ = pure (pure ())

isInvalid : Either RpcError a -> Bool
isInvalid (Left (InvalidResponse _)) = True
isInvalid _ = False

isRemote : Int -> String -> Either RpcError a -> Bool
isRemote status code (Left (RemoteError actual actualCode _)) = status == actual && code == actualCode
isRemote _ _ _ = False

raw : Client -> String -> String -> Cmd (Either RpcError TodoResponse)
raw client body media = client.send
  (MkRequest POST (client.baseUrl ++ "/rpc/v1/todos/create") [("Content-Type", media)] (Just body))
  decodeResponse

runCases : Data.IORef.IORef Nat -> List (String, Cmd (Either RpcError TodoResponse), Either RpcError TodoResponse -> Bool) ->
           IO () -> IO ()
runCases failures [] done = done
runCases failures ((label, command, valid) :: rest) done = do
  _ <- execute command $ \result => do
    check failures label (valid result)
    runCases failures rest done
  pure ()

||| The PG branch starts 24 fetch commands together on the JS/Iris transport.
||| Native Task transport is executed serially by this minimal test dispatcher.
public export
runChecks : Client -> Bool -> (Bool -> IO ()) -> IO ()
runChecks client pooled done = do
  failures <- newIORef 0
  check failures "single-field request requires JSON object"
    (case decodeMaybe {a = CreateTodoRequest} "\"scalar\"" of Nothing => True; _ => False)
  check failures "client rejects numeric identifier"
    (isInvalid (decodeResponse {response = TodoResponse} (Right (MkResponse 200 [] "{\"id\":12,\"title\":\"x\",\"done\":false}"))))
  check failures "client rejects malformed error envelope"
    (isInvalid (decodeResponse {response = TodoResponse} (Left (BadStatus 502 "proxy error"))))
  check failures "transport timeout remains typed"
    (case decodeResponse {response = TodoResponse} (Left Timeout) of Left (TransportFailure Timeout) => True; _ => False)
  let title = "Typed Unicode 🚀 \"quoted\" \\ title"
  let validTodo : Either RpcError TodoResponse -> Bool
      validTodo = \result => case result of
        Right todo => todo.title == title && not todo.done &&
          (if pooled then (the Integer (cast todo.id)) > 9007199254740991
                     else todo.id == "9223372036854775807")
        _ => False
  let cases =
        [ ("generated Iris client round trip with exact BIGINT", createTodo client (MkCreateTodoRequest title) id, validTodo)
        , ("server rejects invalid field type", raw client "{\"title\":42}" "application/json", isRemote 400 "invalid_request")
        , ("server rejects malformed JSON", raw client "{" "application/json", isRemote 400 "invalid_request")
        , ("server rejects unsupported media type", raw client "{\"title\":\"x\"}" "text/plain", isRemote 415 "unsupported_media_type")
        , ("typed domain error", createTodo client (MkCreateTodoRequest "") id, isRemote 400 "invalid_request")
        ]
  let cases = if pooled then cases else cases ++
        [("internal errors are redacted", createTodo client (MkCreateTodoRequest "internal-test") id,
          \result => case result of Left (RemoteError 500 "internal_error" "Internal server error") => True; _ => False)]
  runCases failures cases $ if not pooled then readIORef failures >>= done . (== 0) else do
    remaining <- newIORef (the Nat 24)
    identifiers <- newIORef (the (List String) [])
    traverse_ (\index => do
      let title = "Iris PG client " ++ show index ++ " 🚀"
      _ <- execute (createTodo client (MkCreateTodoRequest title) id) $ \result => do
        case result of
          Right todo => do
            check failures ("pooled create " ++ show index)
              (todo.title == title && not todo.done && (the Integer (cast todo.id)) > 9007199254740991)
            ids <- readIORef identifiers
            writeIORef identifiers (todo.id :: ids)
          Left _ => check failures ("pooled create " ++ show index) False
        n <- readIORef remaining
        writeIORef remaining (n `minus` 1)
        case n of
          1 => do
            ids <- readIORef identifiers
            check failures "24 distinct persisted IDs" (length (nub ids) == 24)
            readIORef failures >>= done . (== 0)
          _ => pure ()
      pure ()) (the (List Nat) [0..23])
