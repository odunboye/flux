module TestSession

import Flux.Core.HTTP
import Flux.Core.Middleware
import Flux.Middleware.Cookies
import Flux.Middleware.Session
import Data.IORef
import Data.SortedMap

%default covering

dummyRequest : Request
dummyRequest = R GET "/" empty V11 empty 0 Nothing (pure (pure ()))

-- Runs an AppProg computation for real, via the async runtime.
runAppProg : AppProg a -> IO (Maybe a)
runAppProg prog = do
  ref <- newIORef Nothing
  runProg $
    handleErrors
      (\case
        Here e         => liftIO (putStrLn "runAppProg: unexpected Errno: \{e}")
        There (Here e) => liftIO (putStrLn "runAppProg: unexpected AppError: \{e.message}"))
      (foreach (\v => liftIO (writeIORef ref (Just v))) (eval prog))
  readIORef ref

-- A fresh visit produces a session cookie and empty session data.
export
testFreshSessionGetsCookie : IO Bool
testFreshSessionGetsCookie = do
  store <- newSessionStore
  mw <- session store
  Just ctx <- runAppProg (mw (emptyContext dummyRequest))
    | Nothing => pure False
  pure $ case ctx.respCookies of
    [c] => c.name == "flux_session"
    _   => False

-- Setting a session value, persisting, then loading it again on a
-- request carrying the same session cookie round-trips the value.
export
testSessionRoundTrip : IO Bool
testSessionRoundTrip = do
  store <- newSessionStore
  mw <- session store

  -- First request: no cookie yet, sets one, sets a session value, persists.
  Just ctx1 <- runAppProg (mw (emptyContext dummyRequest))
    | Nothing => pure False
  let sid = case ctx1.respCookies of
        [c] => c.value
        _   => ""
      ctx1' = setSession "username" "alice" ctx1
  Just _ <- runAppProg (persistSession store ctx1')
    | Nothing => pure False

  -- Second request: carries the session cookie from the first response.
  let req2 = R GET "/" empty V11 (fromList [("cookie", "flux_session=" ++ sid)]) 0 Nothing (pure (pure ()))
  Just ctx2 <- runAppProg (mw (emptyContext req2))
    | Nothing => pure False
  pure (getSession "username" ctx2 == Just "alice")

-- A request with no session data for a key gets Nothing, not a crash.
export
testGetSessionMissing : IO Bool
testGetSessionMissing = do
  store <- newSessionStore
  mw <- session store
  Just ctx <- runAppProg (mw (emptyContext dummyRequest))
    | Nothing => pure False
  pure (getSession "nonexistent" ctx == Nothing)

-- Run all session tests
export
runAllTests : IO (List (String, Bool))
runAllTests = do
  freshCookie <- testFreshSessionGetsCookie
  roundTrip   <- testSessionRoundTrip
  missing     <- testGetSessionMissing
  pure
    [ ("freshSessionGetsCookie", freshCookie)
    , ("sessionRoundTrip", roundTrip)
    , ("getSessionMissing", missing)
    ]
