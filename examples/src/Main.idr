||| A runnable demo server exercising the full feature set: before/after
||| middleware, path params, query strings, PUT/DELETE, a POST handler
||| reading its own JSON body (readBody), structured errors rendered as
||| JSON, cookies/sessions, static file serving, and (manually, via
||| SIGTERM - see the module docs) graceful shutdown draining a slow
||| in-flight request. Run with `[port, workers]` CLI args for the
||| defaults-plus-CLI path (runServerArgs), or `--from-env` for the
||| ServerConfig-driven one (runServerFromConfig, host/port/workers/
||| maxBodySize/timeout all read from FLUX_-prefixed env vars) - see
||| runFromEnv below.
module Main

import Flux.Core.HTTP
import Flux.Core.Router
import Flux.Core.Middleware
import JSON.Simple
import JSON.Simple.Derive
import Flux.Middleware.JSON
import Flux.Server.Config
import Flux.Server.Health
import Flux.Server.Logging
import Flux.Middleware.RequestId
import Flux.Middleware.Timing
import Flux.Middleware.Session
import Flux.Middleware.Static
import Flux.Middleware.Internal.Stripe
import Data.Linear.Ref1
import Data.SortedMap
import Data.List
import Data.Vect
import System

%default covering
%language ElabReflection

public export
record User where
  constructor MkUser
  id    : Integer
  name  : String
  email : String

-- Demonstrates json-simple's derived instances: this used to be a
-- hand-written ToJSON User instance - one line here instead.
%runElab derive "User" [ToJSON]

seedUsers : List User
seedUsers =
  [ MkUser 1 "Alice" "alice@example.com"
  , MkUser 2 "Bob" "bob@example.com"
  ]

parseId : String -> Maybe Integer
parseId s =
  if s /= "" && all isDigit (unpack s) then Just (cast s) else Nothing

-- Sharded the same way Flux.Middleware.RequestId/Session shard their own
-- state (Flux.Middleware.Internal.Stripe): a single shared IORef here
-- was found, under real concurrent POST load, to (a) contend badly
-- between writers - the same class of problem RequestId/Session already
-- had - and (b) let listUsers's full-store scan grow unbounded, since
-- nothing capped how large the store could get. Striping fixes (a); the
-- pagination in listUsers below fixes (b) - striping alone wouldn't
-- have, since the total amount of data to sort/serialize when *listing
-- everything* doesn't shrink just because it's stored across 16 cells
-- instead of one.
0 UserStore : Type
UserStore = Vect 16 (Ref World (SortedMap Integer User))

newUserStore : List User -> IO UserStore
newUserStore seed = do
  stripes <- newStripes empty
  traverse_ (\u => mod (index (keyStripe (show u.id)) stripes) (insert u.id u)) seed
  pure stripes

userStripe : Integer -> UserStore -> Ref World (SortedMap Integer User)
userStripe uid store = index (keyStripe (show uid)) store

getUserById : UserStore -> Integer -> IO (Maybe User)
getUserById store uid = do
  m <- readref (userStripe uid store)
  pure (Data.SortedMap.lookup uid m)

putUserById : UserStore -> Integer -> User -> IO ()
putUserById store uid u = mod (userStripe uid store) (insert uid u)

deleteUserById : UserStore -> Integer -> IO ()
deleteUserById store uid = mod (userStripe uid store) (delete uid)

allUsers : UserStore -> IO (List User)
allUsers store = do
  maps <- traverse readref store
  pure (concatMap Data.SortedMap.values (toList maps))

-- Demo-scale simplification: reading every stripe's current max and then
-- writing the new user isn't one atomic step, so two POSTs racing each
-- other can compute the same "next" id - a real app would want a proper
-- atomic sequence (or just random/UUID ids, sidestepping the question
-- entirely) instead of "1 + the current maximum".
nextUserId : UserStore -> IO Integer
nextUserId store = do
  us <- allUsers store
  pure (1 + foldl max 0 (map (.id) us))

root : Handler
root ctx = pure (sendText "Welcome to Flux!\n" ctx)

defaultPageSize : Nat
defaultPageSize = 20

maxPageSize : Nat
maxPageSize = 100

parseNatParam : Maybe String -> Nat -> Nat
parseNatParam Nothing        def = def
parseNatParam (Just "")      def = def
parseNatParam (Just s)       def =
  if all isDigit (unpack s) then cast s else def

-- Demonstrates pagination: GET /api/users?page=2&pageSize=10. Bounds
-- both the response size and the per-request JSON-encoding cost to
-- pageSize regardless of how large the store has grown - the O(total
-- users) cost of gathering and sorting every stripe's contents to find
-- the right page remains (an in-memory demo has no index to page
-- against directly; a real datastore would).
listUsers : UserStore -> Handler
listUsers store ctx = do
  users <- liftIO (allUsers store)
  -- NB: "total" can't be used as a binding name here - it's a reserved
  -- totality-annotation keyword in this Idris2 version (as in `%default
  -- total`), not just an ordinary identifier; using it as a let-bound
  -- name breaks the parser in a way that has nothing to do with the
  -- multi-binding let itself. Named totalCount instead.
  let sorted     := sortBy (\a, b => compare a.id b.id) users
      totalCount := length sorted
      page       := max 1 (parseNatParam (getQuery "page" ctx.request) 1)
      pageSize   := min maxPageSize (max 1 (parseNatParam (getQuery "pageSize" ctx.request) defaultPageSize))
      offset     := (page `minus` 1) * pageSize
      items      := take pageSize (drop offset sorted)
  pure $ sendJSON (JObject
    [ ("users", toJSON items)
    , ("page", toJSON (cast {to = Integer} page))
    , ("pageSize", toJSON (cast {to = Integer} pageSize))
    , ("total", toJSON (cast {to = Integer} totalCount))
    ]) ctx

-- Demonstrates AppError: an invalid/missing id renders as a JSON error
-- via jsonErrorRenderer (see buildApp) instead of the handler having to
-- hand-build an error response itself.
requireUserId : Context -> AppProg Integer
requireUserId ctx = case getParam "id" ctx.pathParams >>= parseId of
  Just uid => pure uid
  Nothing  => throw (MkAppError 400 "invalid user id")

-- Demonstrates that path params set by the router actually reach the
-- handler via `ctx.pathParams` (previously discarded, see gap #5).
getUser : UserStore -> Handler
getUser store ctx = do
  uid <- requireUserId ctx
  mu  <- liftIO (getUserById store uid)
  case mu of
    Just u  => pure (sendJSON u ctx)
    Nothing => throw (MkAppError 404 "user not found")

-- Demonstrates PUT plus query-string reading: PUT /api/users/1?name=Al
updateUser : UserStore -> Handler
updateUser store ctx = do
  uid <- requireUserId ctx
  case getQuery "name" ctx.request of
    Nothing      => throw (MkAppError 400 "missing ?name= query param")
    Just newName => do
      mu <- liftIO (getUserById store uid)
      case mu of
        Nothing => throw (MkAppError 404 "user not found")
        Just u  => do
          let u' = { name := newName } u
          liftIO (putUserById store uid u')
          pure (sendJSON u' ctx)

-- The maximum size accepted for a createUser request body. Deliberately
-- small here so the "too large" branch below is easy to trigger in
-- manual testing (curl a body over 4096 bytes).
createUserMaxBytes : Nat
createUserMaxBytes = 4096

-- How long a session may go without a request before it's treated as
-- expired and eventually reclaimed by sessionGCLoop (see
-- Flux.Middleware.Session's doc comment) - 30 minutes.
sessionTTLMs : Integer
sessionTTLMs = 1_800_000

-- How often the background sweep actually reclaims expired sessions -
-- doesn't need to be anywhere near as frequent as the TTL itself, since
-- an already-expired session is invisible to `session`'s own idle check
-- regardless of whether the sweep has gotten to it yet.
sessionGCInterval : Clock Duration
sessionGCInterval = 60.s

record NewUser where
  constructor MkNewUser
  name  : String
  email : String

%runElab derive "NewUser" [FromJSON]

-- Demonstrates readBody: reads and JSON-decodes a POST body via the
-- router/Handler layer (previously impossible - see the README's
-- Limitations section this was written to close). A body over
-- createUserMaxBytes gets 413 and the connection closes afterward
-- (readBody forces this - see its doc comment); a body under the limit
-- keeps the connection alive for further pipelined requests exactly like
-- any other request.
createUser : UserStore -> Handler
createUser store ctx = do
  result <- readBody createUserMaxBytes ctx
  case result of
    Left BodyTooLarge => pure (setStatus 413 (sendText "request body too large\n" ctx))
    Left _            => pure (setStatus 400 (sendText "could not read request body\n" ctx))
    Right bytes       => case decodeMaybe {a = NewUser} (Data.ByteString.toString bytes) of
      Nothing => throw (MkAppError 400 "invalid JSON body - expected {\"name\":...,\"email\":...}")
      Just nu => do
        uid <- liftIO (nextUserId store)
        let u = MkUser uid nu.name nu.email
        liftIO (putUserById store uid u)
        pure (setStatus 201 (sendJSON u ctx))

-- Demonstrates DELETE.
deleteUser : UserStore -> Handler
deleteUser store ctx = do
  uid <- requireUserId ctx
  mu  <- liftIO (getUserById store uid)
  case mu of
    Nothing => throw (MkAppError 404 "user not found")
    Just _  => do
      liftIO (deleteUserById store uid)
      pure (setStatus 204 ctx)

-- Demonstrates cookies/sessions: a per-visitor counter that persists
-- across requests via the flux_session cookie.
visits : Handler
visits ctx = do
  let current = fromMaybe 0 (getSession "count" ctx >>= parseId)
      next     = current + 1
      ctx'     = setSession "count" (show next) ctx
  pure (sendJSON (JObject [("visits", toJSON next)]) ctx')

-- Demonstrates graceful shutdown (works on both Linux and macOS - see
-- Flux.Core.HTTP.shutdownOn): start this server, curl /slow, and send
-- SIGTERM while it's in flight. The response should still complete
-- before the process exits, and a second curl started after the signal
-- should fail to connect (no new connections accepted).
slow : Handler
slow ctx = do
  liftIO (System.sleep 3)
  pure (sendText "Finished after 3 seconds\n" ctx)

buildApp : BatchedAccessLog -> IO (App, SessionStore)
buildApp blog = do
  usersStore   <- newUserStore seedUsers
  reqId        <- requestId
  sessionStore <- newSessionStore sessionTTLMs
  let sessionMw = session sessionStore
  let appRouter : Router Handler
      appRouter =
           empty
        |> get    "/" root
        |> get    "/api/users" (listUsers usersStore)
        |> post   "/api/users" (createUser usersStore)
        |> get    "/api/users/:id" (getUser usersStore)
        |> put    "/api/users/:id" (updateUser usersStore)
        |> delete "/api/users/:id" (deleteUser usersStore)
        |> get    "/visits" visits
        |> get    "/slow" slow
        |> get    "/static/*path" (staticHandler "public" defaultMimeFor)
        |> healthRoutes (addCheck (memoryCheck 512) emptyRegistry) "0.2.0"

  let application = app
        |> withErrorRenderer jsonErrorRenderer
        |> use corsAllowAll
        |> use secureHeaders
        |> use reqId
        |> use timing
        |> use sessionMw
        |> useAfter responseTime
        |> useAfter (persistSession sessionStore)
        -- CORS/security headers and the request ID must survive even a
        -- request that errors out (`before`'s effects are discarded on
        -- that path - see App's doc comment); requestAccessLog moves here
        -- entirely (not also left under useAfter) so a failing request
        -- still gets one log entry, not zero.
        |> useAlways corsAllowAll
        |> useAlways secureHeaders
        |> useAlways reqId
        |> useAlways (requestAccessLog blog)
        |> withRoutes appRouter
  pure (application, sessionStore)

-- Demonstrates runServerFromConfig: every tuning knob (host/port/
-- workers/maxBodySize/timeout) comes from a real ServerConfig instead of
-- CLI args, e.g. FLUX_SERVER_HOST=0.0.0.0 FLUX_SERVER_PORT=9090
-- ./flux-examples --from-env. Try posting a body over 1MB (the default
-- maxBodySize, unless FLUX_SERVER_MAXBODYSIZE overrides it) to any POST
-- route to see the config-driven limit actually enforced.
runFromEnv : App -> SessionStore -> BatchedAccessLog -> IO ()
runFromEnv application sessionStore blog = do
  cfg <- serverConfigFromEnv
  runProgWith
    [accessFlushLoop 50.ms blog, sessionGCLoop sessionGCInterval sessionStore]
    (runServerFromConfig (runApp application) cfg)

covering
main : IO ()
main = do
  blog                    <- newBatchedAccessLog
  (application, sessions) <- buildApp blog
  args <- getArgs
  let background = [accessFlushLoop 50.ms blog, sessionGCLoop sessionGCInterval sessions]
  case args of
    _ :: "--from-env" :: _ => runFromEnv application sessions blog
    _ :: t                 => runProgWith background (runServerArgs (runApp application) t)
    []                      => runProgWith background (runServerArgs (runApp application) [])
  flushAccessLog blog

