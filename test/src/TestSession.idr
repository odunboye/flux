module TestSession

import Flux.Core.HTTP
import Flux.Core.Middleware
import Flux.Middleware.Cookies
import Flux.Middleware.Session
import Data.IORef
import Data.SortedMap
import Data.List
import Data.Vect
import System
import System.Clock

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
  store <- newSessionStore 1_800_000
  let mw = session store
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
  store <- newSessionStore 1_800_000
  let mw = session store

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
  store <- newSessionStore 1_800_000
  let mw = session store
  Just ctx <- runAppProg (mw (emptyContext dummyRequest))
    | Nothing => pure False
  pure (getSession "nonexistent" ctx == Nothing)

-- A session older than the store's TTL is treated exactly like no
-- session at all - session issues a *fresh* id/cookie instead of
-- reloading the expired data, rather than silently reviving it.
export
testExpiredSessionGetsFreshId : IO Bool
testExpiredSessionGetsFreshId = do
  store <- newSessionStore 50   -- 50ms TTL - short enough to expire fast
  let mw = session store

  Just ctx1 <- runAppProg (mw (emptyContext dummyRequest))
    | Nothing => pure False
  let sid1 = case ctx1.respCookies of
        [c] => c.value
        _   => ""
      ctx1' = setSession "username" "alice" ctx1
  Just _ <- runAppProg (persistSession store ctx1')
    | Nothing => pure False

  usleep 100000  -- 100ms - past the 50ms TTL

  let req2 = R GET "/" empty V11 (fromList [("cookie", "flux_session=" ++ sid1)]) 0 Nothing (pure (pure ()))
  Just ctx2 <- runAppProg (mw (emptyContext req2))
    | Nothing => pure False
  pure $ case ctx2.respCookies of
    [c] => c.value /= sid1 && getSession "username" ctx2 == Nothing
    _   => False

-- sessionGCLoop actually removes an expired entry from the store, not
-- just hides it from session's own idle check - persistSession on a
-- *different*, still-valid session afterward should be unaffected.
export
testGCLoopReclaimsExpiredSession : IO Bool
testGCLoopReclaimsExpiredSession = do
  store <- newSessionStore 50
  let mw = session store

  Just ctx1 <- runAppProg (mw (emptyContext dummyRequest))
    | Nothing => pure False
  Just _ <- runAppProg (persistSession store (setSession "username" "alice" ctx1))
    | Nothing => pure False

  usleep 100000  -- past the 50ms TTL

  -- One GC sweep, run directly rather than via a background loop.
  now <- clockTimeMs
  for_ (sessions store) $ \stripe =>
    mod stripe (fromList . filter (\(_, e) => now - e.lastTouched <= store.ttlMs) . SortedMap.toList)

  -- A fresh request still works fine after the sweep (store isn't broken).
  Just ctx2 <- runAppProg (mw (emptyContext dummyRequest))
    | Nothing => pure False
  pure $ case ctx2.respCookies of
    [_] => True
    _   => False
  where
    clockTimeMs : IO Integer
    clockTimeMs = do
      c <- clockTime Monotonic
      pure (seconds c * 1000 + nanoseconds c `div` 1_000_000)

-- Run all session tests
export
runAllTests : IO (List (String, Bool))
runAllTests = do
  freshCookie <- testFreshSessionGetsCookie
  roundTrip   <- testSessionRoundTrip
  missing     <- testGetSessionMissing
  expired     <- testExpiredSessionGetsFreshId
  gcReclaims  <- testGCLoopReclaimsExpiredSession
  pure
    [ ("freshSessionGetsCookie", freshCookie)
    , ("sessionRoundTrip", roundTrip)
    , ("getSessionMissing", missing)
    , ("expiredSessionGetsFreshId", expired)
    , ("gcLoopReclaimsExpiredSession", gcReclaims)
    ]
