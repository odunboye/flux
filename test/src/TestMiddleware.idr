module TestMiddleware

import Flux.Core.Middleware
import Flux.Core.Router
import Flux.Core.HTTP
import Data.IORef
import Data.String
import System

%default covering

export
testEmptyApp : Bool
testEmptyApp =
  case emptyApp of
    MkApp r _ _ _ =>
      case matchRoute GET "/any" r of
        NoMatch => True
        _ => False

-- `use` adds to the before-chain
export
testUse : Bool
testUse =
  let mw : Middleware
      mw = pure
      app1 = use mw emptyApp
   in case app1 of
        MkApp _ before _ _ => length before == 1

-- `useAfter` adds to the after-chain, independently of `use`
export
testUseAfter : Bool
testUseAfter =
  let mw : Middleware
      mw = pure
      app1 = useAfter mw emptyApp
   in case app1 of
        MkApp _ before after _ => length before == 0 && length after == 1

export
testWithRoutes : Bool
testWithRoutes =
  let handler : Handler
      handler = pure
      router = get "/test" handler empty
      app1 = withRoutes router emptyApp
   in case app1 of
        MkApp r _ _ _ =>
          case matchRoute GET "/test" r of
            Matched _ _ => True
            _           => False

--------------------------------------------------------------------------------
-- End-to-end: does runApp actually catch failures and render a response,
-- rather than letting them propagate and silently drop the connection?
--------------------------------------------------------------------------------

-- A bare request with no body, just enough to drive runApp end-to-end.
dummyRequest : Request
dummyRequest = R GET "/" empty V11 empty 0 Nothing (pure ())

-- Runs an HTTPProg computation for real, via the async runtime, and
-- returns its result - needed because runApp's error-catching is a
-- runtime behavior, not something visible from its type alone.
runOnce : HTTPProg a -> IO (Maybe a)
runOnce prog = do
  ref <- newIORef Nothing
  runProg $
    handleErrors
      (\case
        Here e         => liftIO (putStrLn "runOnce: unexpected Errno: \{e}")
        There (Here e) => liftIO (putStrLn "runOnce: unexpected HTTPErr: \{e}"))
      (foreach (\v => liftIO (writeIORef ref (Just v))) (eval prog))
  readIORef ref

export
testRunAppCatchesAppError : IO Bool
testRunAppCatchesAppError = do
  let failingHandler : Handler
      failingHandler _ = throw (MkAppError 404 "not found")
      myApp = withRoutes (get "/" failingHandler empty) emptyApp
  Just resp <- runOnce (runApp myApp dummyRequest)
    | Nothing => pure False
  let respStr = toString resp
  pure $ isInfixOf "404" respStr && isInfixOf "not found" respStr

export
testRunAppCatchesErrno : IO Bool
testRunAppCatchesErrno = do
  let failingHandler : Handler
      failingHandler _ = throw EPERM
      myApp = withRoutes (get "/" failingHandler empty) emptyApp
  Just resp <- runOnce (runApp myApp dummyRequest)
    | Nothing => pure False
  let respStr = toString resp
  pure $ isInfixOf "500" respStr

export
testWithErrorRenderer : IO Bool
testWithErrorRenderer = do
  let failingHandler : Handler
      failingHandler _ = throw (MkAppError 418 "teapot")
      myApp = withErrorRenderer (\err => setStatus err.status . sendText ("custom: " ++ err.message)) $
                withRoutes (get "/" failingHandler empty) emptyApp
  Just resp <- runOnce (runApp myApp dummyRequest)
    | Nothing => pure False
  let respStr = toString resp
  pure $ isInfixOf "418" respStr && isInfixOf "custom: teapot" respStr

-- Run all middleware tests (mixing pure and IO-backed cases, since the
-- end-to-end runApp tests are inherently effectful)
export
runAllTests : IO (List (String, Bool))
runAllTests = do
  appErrorResult    <- testRunAppCatchesAppError
  errnoResult       <- testRunAppCatchesErrno
  errorRendererResult <- testWithErrorRenderer
  pure
    [ ("emptyApp", testEmptyApp)
    , ("use", testUse)
    , ("useAfter", testUseAfter)
    , ("withRoutes", testWithRoutes)
    , ("runAppCatchesAppError", appErrorResult)
    , ("runAppCatchesErrno", errnoResult)
    , ("withErrorRenderer", errorRendererResult)
    ]
