||| A minimal in-memory, cookie-backed session store.
|||
||| Deliberately basic: sessions live only for the process's lifetime (no
||| persistence), never expire, and are never garbage-collected - a long-
||| running server will accumulate one entry per distinct visitor forever.
||| Session IDs are a process-local counter, not a cryptographically
||| random token (this dependency stack has no obvious CSPRNG), so they
||| are guessable - do not rely on them as an unforgeable auth credential
||| without hardening this. Good enough for a demo or a low-stakes app;
||| swap in something real (Redis-backed, expiring, random IDs) for
||| production use.
module Flux.Middleware.Session

import public Flux.Core.HTTP
import public Flux.Core.Middleware
import Flux.Middleware.Cookies
import Data.Linear.Ref1
import Data.List
import Data.String

%default covering

||| `sessions` is a `Data.Linear.Ref1` reference, updated via `mod` (a
||| lock-free compare-and-swap loop) in `persistSession`: with more than
||| one async worker thread, concurrent requests can genuinely run these
||| updates in parallel on different OS threads, and a bare
||| read-then-write on a plain `Data.IORef` is not atomic across threads -
||| two concurrent persists could each read the same map and one's insert
||| would be silently lost. CAS-retry also scales better under contention
||| than a `Mutex` would, since it never blocks a thread in the kernel.
public export
record SessionStore where
  constructor MkSessionStore
  sessions : Ref World (SortedMap String (SortedMap String String))

export
newSessionStore : IO SessionStore
newSessionStore = MkSessionStore <$> newref empty

sessionIdCookie : String
sessionIdCookie = "flux_session"

sessionIdKey : String
sessionIdKey = "session.id"

-- Session data lives in Context.state under this prefix, so it doesn't
-- collide with unrelated middleware using state directly.
sessionPrefix : String
sessionPrefix = "session.data."

export
getSession : String -> Context -> Maybe String
getSession key ctx = getState (sessionPrefix ++ key) ctx

export
setSession : String -> String -> Context -> Context
setSession key value = setState (sessionPrefix ++ key) value

||| Builds the session before-hook: reuses the `flux_session` cookie if
||| the request already has one (creating and setting a new one
||| otherwise), then loads that session's stored data into Context state
||| (see `getSession`). Register with `use`, before any handler that reads
||| session data. Call once at startup - `Middleware` values close over
||| the counter used to generate fresh session IDs.
|||
||| The counter is a `Data.Linear.Ref1` reference too, incremented via
||| `update` for the same reason `sessions` uses `mod`: concurrent
||| requests on different worker threads can race on a bare `IORef`
||| read-then-write.
resolveSessionId : Ref World Nat -> Maybe String -> AppProg String
resolveSessionId _       (Just sid) = pure sid
resolveSessionId counter Nothing    = liftIO $ do
  n <- update counter (\n => (S n, n))
  pure ("sess-" ++ show n)

export
session : SessionStore -> IO Middleware
session store = do
  counter <- newref 0
  pure $ \ctx => Prelude.do
    let existing := getCookie sessionIdCookie ctx
    sid <- resolveSessionId counter existing
    sessionData <- liftIO $ do
      allSessions <- readref (sessions store)
      pure (fromMaybe empty (Data.SortedMap.lookup sid allSessions))
    let ctxWithData := foldl (\c,(k,v) => setSession k v c) ctx (SortedMap.toList sessionData)
        ctxWithCookie := case existing of
          Just _  => ctxWithData
          Nothing => addCookie (cookie sessionIdCookie sid) ctxWithData
    pure (setState sessionIdKey sid ctxWithCookie)

extractSessionData : Context -> SortedMap String String
extractSessionData ctx = fromList (mapMaybe stripPrefix (SortedMap.toList ctx.state))
  where
    stripPrefix : (String, String) -> Maybe (String, String)
    stripPrefix (k, v) =
      if sessionPrefix `isPrefixOf` k
        then Just (substr (length sessionPrefix) (length k) k, v)
        else Nothing

||| Builds the session after-hook: persists whatever session data (see
||| `setSession`) the request accumulated back into the shared store.
||| Register with `useAfter`, after `session` has been registered with
||| `use`.
export
persistSession : SessionStore -> Middleware
persistSession store ctx =
  case getState sessionIdKey ctx of
    Nothing  => pure ctx
    Just sid => Prelude.do
      liftIO $ mod (sessions store) (insert sid (extractSessionData ctx))
      pure ctx
