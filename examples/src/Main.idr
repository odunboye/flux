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

buildApp : IO App
buildApp = do
  usersStore   <- Data.IORef.newIORef (fromList (map (\u => (u.id, u)) seedUsers))
  reqId        <- requestId
  sessionStore <- newSessionStore
  sessionMw    <- session sessionStore
  let logger = mkLogger Info

      appRouter : Router Handler
      appRouter =
           empty
        |> get    "/" root
        |> get    "/api/users" (listUsers usersStore)
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
    |> useAfter (requestLog logger)
    |> useAfter (persistSession sessionStore)
    |> withRoutes appRouter

covering
main : IO ()
main = do
  application <- buildApp
  _ :: t <- getArgs | [] => runProg (runServerArgs (runApp application) [])
  runProg (runServerArgs (runApp application) t)
