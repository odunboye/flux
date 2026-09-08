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
import Flux.Middleware.Internal.Stripe
import Data.Linear.Ref1
import Data.Fin
import Data.List
import Data.String
import Data.Vect

%default covering

||| `sessions` is sharded into 16 independent `Data.Linear.Ref1`
||| stripes (see `Flux.Middleware.Internal.Stripe`), each updated via
||| `mod` (a lock-free compare-and-swap loop) in `persistSession`. A
||| session's ID picks its stripe deterministically (`keyStripe`), so
||| `session` and `persistSession` always agree on which one holds it.
|||
||| A single shared map, however it's guarded, is still one cache line
||| that every worker thread's concurrent requests all contend for -
||| under real parallel load that contention itself becomes the
||| bottleneck. Sharding by session ID spreads different sessions
||| across independent cache lines instead, while still letting a
||| lookup for a given session go straight to the one stripe that could
||| hold it.
public export
record SessionStore where
  constructor MkSessionStore
  sessions : Vect 16 (Ref World (SortedMap String (SortedMap String String)))

export
newSessionStore : IO SessionStore
newSessionStore = MkSessionStore <$> newStripes empty

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
||| the counters used to generate fresh session IDs.
|||
||| Fresh IDs look like `"sess-<stripe>-<n>"` rather than a single
||| incrementing `"sess-<n>"`, for the same reason `RequestId`'s
||| generator is striped: one shared counter is one contended cache
||| line under real concurrency, no matter how it's guarded.
resolveSessionId : Vect 16 (Ref World Nat) -> Maybe String -> AppProg String
resolveSessionId _       (Just sid) = pure sid
resolveSessionId counter Nothing    = liftIO $ do
  i <- randomStripe
  n <- update (index i counter) (\n => (S n, n))
  pure ("sess-" ++ show (finToNat i) ++ "-" ++ show n)

export
session : SessionStore -> IO Middleware
session store = do
  counter <- newStripes 0
  pure $ \ctx => Prelude.do
    let existing := getCookie sessionIdCookie ctx
    sid <- resolveSessionId counter existing
    sessionData <- liftIO $ do
      allSessions <- readref (index (keyStripe sid) (sessions store))
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
      liftIO $ mod (index (keyStripe sid) (sessions store)) (insert sid (extractSessionData ctx))
      pure ctx
