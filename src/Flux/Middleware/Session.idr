||| A minimal in-memory, cookie-backed session store.
|||
||| Deliberately basic: sessions live only for the process's lifetime -
||| no persistence across restarts, no sharing across processes/a
||| cluster. Session IDs are 128 bits of real OS entropy
||| (`Flux.Middleware.Internal.Random`, reading `/dev/urandom` directly
||| - not Idris2's own `System.Random`, which is not cryptographically
||| secure - see that module's doc comment), so they're not guessable;
||| sessions expire after `ttlMs` of inactivity and a background sweep
||| (`sessionGCLoop`) actually reclaims expired entries rather than
||| letting them accumulate forever. What's still missing for real
||| production use: persistence across restarts and sharing across more
||| than one process - swap in something real (Redis-backed, etc.) for
||| that.
module Flux.Middleware.Session

import public Flux.Core.HTTP
import public Flux.Core.Middleware
import Flux.Middleware.Cookies
import Flux.Middleware.Internal.Stripe
import Flux.Middleware.Internal.Random
import Data.Linear.Ref1
import Data.Fin
import Data.List
import Data.String
import Data.Vect
import System.Clock

%default covering

-- Same monotonic-ms representation as Flux.Middleware.Timing.getTimeMs,
-- duplicated locally rather than importing Timing (which pulls in
-- Flux.Server.Logging - too much for one timestamp helper).
nowMs : IO Integer
nowMs = do
  c <- clockTime Monotonic
  pure (seconds c * 1000 + nanoseconds c `div` 1_000_000)

||| One stored session: its data, plus when it was last touched (see
||| `persistSession`) - used by `session` to decide whether it's expired
||| (treated exactly like "no such session" if so - see `session`) and
||| by `sessionGCLoop` to actually remove it once it is.
public export
record SessionEntry where
  constructor MkSessionEntry
  lastTouched : Integer
  sessionData : SortedMap String String

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
  ttlMs    : Integer
  sessions : Vect 16 (Ref World (SortedMap String SessionEntry))

||| `ttlMs`: how long a session may go without a request before it's
||| treated as expired (see `session`) and eventually reclaimed (see
||| `sessionGCLoop`) - reset on every request that touches it
||| (`persistSession` bumps `lastTouched` unconditionally).
export
newSessionStore : (ttlMs : Integer) -> IO SessionStore
newSessionStore ttlMs = MkSessionStore ttlMs <$> newStripes empty

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

-- How much entropy a fresh session ID carries - 128 bits, the same
-- size commonly used for session tokens elsewhere (e.g. a UUIDv4's
-- random bits).
sessionIdBytes : Bits32
sessionIdBytes = 16

||| Builds the session before-hook: reuses the `flux_session` cookie if
||| the request has one *and* it hasn't expired (see `SessionStore.ttlMs`)
||| - otherwise (no cookie, or an expired one) issues a fresh,
||| `Flux.Middleware.Internal.Random`-backed session ID, exactly as if
||| there had never been a cookie at all - then loads that session's
||| stored data into Context state (see `getSession`). Register with
||| `use`, before any handler that reads session data.
export
session : SessionStore -> Middleware
session store ctx = Prelude.do
  now   <- liftIO nowMs
  entry <- case getCookie sessionIdCookie ctx of
    Nothing  => pure Nothing
    Just sid => do
      allSessions <- liftIO (readref (index (keyStripe sid) (sessions store)))
      pure $ case Data.SortedMap.lookup sid allSessions of
        Just e => if now - e.lastTouched <= store.ttlMs then Just (sid, e.sessionData) else Nothing
        Nothing => Nothing
  case entry of
    Just (sid, sessionData) =>
      pure $ setState sessionIdKey sid $
        foldl (\c,(k,v) => setSession k v c) ctx (SortedMap.toList sessionData)
    Nothing => do
      sid <- ("sess-" ++) <$> widenErrors (randomToken sessionIdBytes)
      pure $ setState sessionIdKey sid (addCookie (cookie sessionIdCookie sid) ctx)

extractSessionData : Context -> SortedMap String String
extractSessionData ctx = fromList (mapMaybe stripPrefix (SortedMap.toList ctx.state))
  where
    stripPrefix : (String, String) -> Maybe (String, String)
    stripPrefix (k, v) =
      if sessionPrefix `isPrefixOf` k
        then Just (substr (length sessionPrefix) (length k) k, v)
        else Nothing

||| Builds the session after-hook: persists whatever session data (see
||| `setSession`) the request accumulated back into the shared store,
||| and bumps `lastTouched` to now - the thing that actually keeps an
||| active session from expiring under `session`'s idle check. Register
||| with `useAfter`, after `session` has been registered with `use`.
export
persistSession : SessionStore -> Middleware
persistSession store ctx =
  case getState sessionIdKey ctx of
    Nothing  => pure ctx
    Just sid => Prelude.do
      now <- liftIO nowMs
      liftIO $ mod (index (keyStripe sid) (sessions store))
        (insert sid (MkSessionEntry now (extractSessionData ctx)))
      pure ctx

||| Periodically scans every stripe and removes any session whose last
||| activity is older than `SessionStore.ttlMs`. Without this, an
||| expired session - already invisible to `session`'s own idle check -
||| would still sit in the store forever, since nothing else ever
||| removes it; the store would still grow without bound, just with
||| dead entries instead of live ones. Race this alongside the server
||| the same way as `Flux.Server.Logging.flushLoop`/`accessFlushLoop`,
||| e.g. `runProgWith [sessionGCLoop 60.s sessionStore] ...`.
export covering
sessionGCLoop : Clock Duration -> SessionStore -> Async Poll [] ()
sessionGCLoop interval store = do
  sleep interval
  liftIO $ do
    now <- nowMs
    for_ (sessions store) $ \stripe =>
      mod stripe (fromList . filter (\(_, e) => now - e.lastTouched <= store.ttlMs) . SortedMap.toList)
  sessionGCLoop interval store
