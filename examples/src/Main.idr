||| A runnable demo server exercising the full feature set: before/after
||| middleware, path params, query strings, PUT/DELETE, structured errors
||| rendered as JSON, cookies/sessions, static file serving, and (manually,
||| via SIGTERM - see the module docs) graceful shutdown draining a slow
||| in-flight request.
module Main

import Flux.Core.HTTP
import Flux.Core.Router
import Flux.Core.Middleware
import Flux.Data.JSON
import Flux.Server.Health
import Flux.Server.Logging
import Flux.Middleware.RequestId
import Flux.Middleware.Timing
import Flux.Middleware.Session
import Flux.Middleware.Static
import Data.SortedMap
import Data.List
import Data.IORef
import System

%default covering

public export
record User where
  constructor MkUser
  id    : Integer
  name  : String
  email : String

export
ToJSON User where
  toJSON (MkUser id name email) =
    JObject (fromList [("id", toJSON id), ("name", toJSON name), ("email", toJSON email)])

seedUsers : List User
seedUsers =
  [ MkUser 1 "Alice" "alice@example.com"
  , MkUser 2 "Bob" "bob@example.com"
  ]

parseId : String -> Maybe Integer
parseId s =
  if s /= "" && all isDigit (unpack s) then Just (cast s) else Nothing

0 UserStore : Type
UserStore = Data.IORef.IORef (SortedMap Integer User)

root : Handler
root ctx = pure (sendText "Welcome to Flux!\n" ctx)

listUsers : UserStore -> Handler
listUsers store ctx = do
  users <- liftIO (Data.IORef.readIORef store)
  pure (sendJSON (Data.SortedMap.values users) ctx)

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
  users <- liftIO (Data.IORef.readIORef store)
  case Data.SortedMap.lookup uid users of
    Just u  => pure (sendJSON u ctx)
    Nothing => throw (MkAppError 404 "user not found")

-- Demonstrates PUT plus query-string reading: PUT /api/users/1?name=Al
updateUser : UserStore -> Handler
updateUser store ctx = do
  uid <- requireUserId ctx
  case getQuery "name" ctx.request of
    Nothing      => throw (MkAppError 400 "missing ?name= query param")
    Just newName => do
      users <- liftIO (Data.IORef.readIORef store)
      case Data.SortedMap.lookup uid users of
        Nothing => throw (MkAppError 404 "user not found")
        Just u  => do
          let u' = { name := newName } u
          liftIO (Data.IORef.modifyIORef store (insert uid u'))
          pure (sendJSON u' ctx)

-- The maximum size accepted for a createUser request body. Deliberately
-- small here so the "too large" branch below is easy to trigger in
-- manual testing (curl a body over 4096 bytes).
createUserMaxBytes : Nat
createUserMaxBytes = 4096

record NewUser where
  constructor MkNewUser
  name  : String
  email : String

FromJSON NewUser where
  fromJSON (JObject kvs) = do
    JString n <- Data.SortedMap.lookup "name" kvs  | _ => Nothing
    JString e <- Data.SortedMap.lookup "email" kvs | _ => Nothing
    pure (MkNewUser n e)
  fromJSON _ = Nothing

nextUserId : SortedMap Integer User -> Integer
nextUserId users = 1 + foldl max 0 (map (.id) (Data.SortedMap.values users))

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
    Right bytes       => case decode {a = NewUser} (toString bytes) of
      Nothing => throw (MkAppError 400 "invalid JSON body - expected {\"name\":...,\"email\":...}")
      Just nu => do
        users <- liftIO (Data.IORef.readIORef store)
        let uid = nextUserId users
            u   = MkUser uid nu.name nu.email
        liftIO (Data.IORef.modifyIORef store (insert uid u))
        pure (setStatus 201 (sendJSON u ctx))

-- Demonstrates DELETE.
deleteUser : UserStore -> Handler
deleteUser store ctx = do
  uid <- requireUserId ctx
  users <- liftIO (Data.IORef.readIORef store)
  case Data.SortedMap.lookup uid users of
    Nothing => throw (MkAppError 404 "user not found")
    Just _  => do
      liftIO (Data.IORef.modifyIORef store (delete uid))
      pure (setStatus 204 ctx)

-- Demonstrates cookies/sessions: a per-visitor counter that persists
-- across requests via the flux_session cookie.
visits : Handler
visits ctx = do
  let current = fromMaybe 0 (getSession "count" ctx >>= parseId)
      next     = current + 1
      ctx'     = setSession "count" (show next) ctx
  pure (sendJSON (JObject (fromList [("visits", toJSON next)])) ctx')

-- Demonstrates graceful shutdown: start this server, curl /slow, and
-- send SIGTERM (on Linux - see Flux.Core.HTTP.shutdownOn's platform
-- note) while it's in flight. The response should still complete before
-- the process exits, and a second curl started after the signal should
-- fail to connect (no new connections accepted).
slow : Handler
slow ctx = do
  liftIO (System.sleep 3)
  pure (sendText "Finished after 3 seconds\n" ctx)

buildApp : BatchedAccessLog -> IO App
buildApp blog = do
  usersStore   <- Data.IORef.newIORef (fromList (map (\u => (u.id, u)) seedUsers))
  reqId        <- requestId
  sessionStore <- newSessionStore
  sessionMw    <- session sessionStore
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
        |> healthRoutes emptyRegistry "0.2.0"

  pure $ app
    |> withErrorRenderer jsonErrorRenderer
    |> use corsAllowAll
    |> use secureHeaders
    |> use reqId
    |> use timing
    |> use sessionMw
    |> useAfter responseTime
    |> useAfter (requestAccessLog blog)
    |> useAfter (persistSession sessionStore)
    |> withRoutes appRouter

covering
main : IO ()
main = do
  blog        <- newBatchedAccessLog
  application <- buildApp blog
  args <- getArgs
  let progArgs = case args of
        _ :: t => t
        []     => []
  runProgWith [accessFlushLoop 50.ms blog] (runServerArgs (runApp application) progArgs)
  flushAccessLog blog
