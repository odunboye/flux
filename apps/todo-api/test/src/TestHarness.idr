||| Shared `runApp`-driving test harness - request building, response
||| parsing, and pass/fail bookkeeping - used by both `Main` (the real-
||| Postgres suite) and `InMemoryMain` (the zero-Postgres suite), so
||| neither duplicates it. Mirrors how Flux's own test suite exercises
||| `runApp` end-to-end, not through a live HTTP connection.
module TestHarness

import public Flux.Core.HTTP
import public Flux.Core.Middleware
import Data.IORef
import Data.Maybe
import Data.String
import System

%default covering

export
mkBody : List ByteString -> HTTPBody
mkBody []        = pure (pure ())
mkBody (c :: cs) = emit c >> mkBody cs

export
mkRequest : Method -> String -> Request
mkRequest m path = R m path empty V11 empty 0 Nothing (pure (pure ()))

export
mkRequestWithBody : Method -> String -> String -> Request
mkRequestWithBody m path bodyStr =
  let chunks := [fromString bodyStr]
   in R m path empty V11 empty (sum (map length chunks)) (Just "application/json") (mkBody chunks)

-- Runs an HTTPPull for real, via the async runtime, concatenating
-- everything it emits - needed because runApp's error-catching is a
-- runtime behavior, not something visible from its type alone. Mirrors
-- Flux's own test suite's `runOnce`.
export
runOnce : HTTPPull ByteString r -> IO ByteString
runOnce stream = do
  ref <- Data.IORef.newIORef []
  runProg $
    handleErrors
      (\case
        Here _         => liftIO (putStrLn "runOnce: unexpected Errno")
        There (Here _) => liftIO (putStrLn "runOnce: unexpected HTTPErr"))
      (Prelude.ignore (foreach (\v => liftIO (Data.IORef.modifyIORef ref (v ::))) stream))
  chunks <- Data.IORef.readIORef ref
  pure (fastConcat (reverse chunks))

public export
record Resp where
  constructor MkResp
  status : Nat
  body   : String

-- Finds the first occurrence of `sep` in `s`, returning the text before
-- and after it.
export
splitOnFirst : String -> String -> Maybe (String, String)
splitOnFirst sep s = go 0
  where
    n : Nat
    n = length s

    sepLen : Nat
    sepLen = length sep

    go : Nat -> Maybe (String, String)
    go i =
      if i + sepLen > n then Nothing
      else if substr i sepLen s == sep
        then Just (substr 0 i s, substr (i + sepLen) (n `minus` (i + sepLen)) s)
        else go (S i)

-- Splits a raw wire response into (status, body) for assertions -
-- `runApp` always writes a real status line ("HTTP/1.1 <code>") and a
-- blank line before the body (see `Flux.Core.Middleware.render`), so
-- this is a plain, reliable split, not a heuristic. Status is read via
-- `words` on the first line specifically (not "every digit in the
-- response"), since naively filtering digits would also pick up the
-- "1"s from "HTTP/1.1" itself.
export
splitResponse : ByteString -> Resp
splitResponse raw =
  let s          := toString raw
      statusLine := fst (break (== '\r') s)
      statusCode := case words statusLine of
        [_, code] => fromMaybe 0 (parsePositive {a = Nat} code)
        _         => 0
      body := case splitOnFirst "\r\n\r\n" s of
        Just (_, rest) => rest
        Nothing        => ""
   in MkResp statusCode body

export
run : App -> Request -> IO Resp
run application req = do
  raw <- runOnce (runApp application req)
  pure (splitResponse raw)

public export
record TestState where
  constructor MkTestState
  passed : Nat
  failed : List String

export
check : Data.IORef.IORef TestState -> String -> Bool -> IO ()
check st name ok = do
  if ok
     then do
       putStrLn "  [PASS] \{name}"
       Data.IORef.modifyIORef st (\s => { passed := S s.passed } s)
     else do
       putStrLn "  [FAIL] \{name}"
       Data.IORef.modifyIORef st (\s => { failed := name :: s.failed } s)

||| Prints the final pass/fail tally and exits non-zero if anything
||| failed - shared by both entry points so neither suite can print
||| `[FAIL] ...` lines and still exit 0.
export
report : Data.IORef.IORef TestState -> IO ()
report st = do
  final <- Data.IORef.readIORef st
  let totalCount = final.passed + length final.failed
  putStrLn "\n========================================"
  putStrLn "Total: \{show totalCount} | Passed: \{show final.passed} | Failed: \{show (length final.failed)}"
  putStrLn "========================================"
  case final.failed of
    [] => putStrLn "All tests passed!"
    fs => do
      putStrLn "Failed: \{show (reverse fs)}"
      exitFailure
