module Main

import Protocol
import System

%default covering

-- Protocol smoke application, not a persistence implementation. The large ID
-- deliberately exceeds JavaScript's exact integer range and travels as text.
createTodo : CreateTodoRequest -> AppProg TodoResponse
createTodo request = do
  if request.title == "" then throw (MkAppError 400 "Title must not be empty")
    else if request.title == "internal-test" then throw (MkAppError 500 "secret database detail")
    else do
      if request.title == "slow-test" then sleep 1000 else pure ()
      pure (MkTodoResponse False "9223372036854775807" request.title)

main : IO ()
main = do
  args <- getArgs
  let application = app |> useAlways corsAllowAll |> withErrorRenderer rpcErrorRenderer
                        |> withRoutes (routes (MkApi createTodo))
  runProg (runServerArgs (runApp application) (drop 1 args))
