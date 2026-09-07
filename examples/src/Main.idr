||| A runnable demo server exercising the full App pipeline: before/after
||| middleware, path params, and IO-backed handlers, so the fix to how
||| Context flows from middleware through to the rendered response is
||| actually exercised end-to-end (not just at the type level).
module Main

import Flux.Core.HTTP
import Flux.Core.Router
import Flux.Core.Middleware
import Flux.Data.JSON
import Flux.Server.Health
import Flux.Server.Logging
import Flux.Middleware.RequestId
import Flux.Middleware.Timing
import Data.SortedMap
import Data.List
import System

%default total

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

users : List User
users =
  [ MkUser 1 "Alice" "alice@example.com"
  , MkUser 2 "Bob" "bob@example.com"
  ]

parsePositive : String -> Maybe Integer
parsePositive s =
  if s /= "" && all isDigit (unpack s) then Just (cast s) else Nothing

notFoundJSON : Context -> Context
notFoundJSON = sendJSONError 404 "user not found"

root : Handler
root ctx = pure (sendText "Welcome to Flux!\n" ctx)

listUsers : Handler
listUsers ctx = pure (sendJSON users ctx)

-- Demonstrates that path params set by the router actually reach the
-- handler via `ctx.pathParams` (previously discarded, see gap #5).
getUser : Handler
getUser ctx = pure $ case getParam "id" ctx.pathParams >>= parsePositive of
  Nothing  => notFoundJSON ctx
  Just uid => case find (\u => u.id == uid) users of
    Just u  => sendJSON u ctx
    Nothing => notFoundJSON ctx

appRouter : Router Handler
appRouter =
     empty
  |> get "/" root
  |> get "/api/users" listUsers
  |> get "/api/users/:id" getUser
  |> healthRoutes emptyRegistry "0.2.0"

-- Demonstrates that `use`/`useAfter` middleware actually affects the
-- rendered response: CORS/security headers, a generated request ID, and a
-- response-time header should all show up on every request.
buildApp : IO App
buildApp = do
  reqId <- requestId
  let logger = mkLogger Info
  pure $ app
    |> use corsAllowAll
    |> use secureHeaders
    |> use reqId
    |> use timing
    |> useAfter responseTime
    |> useAfter (requestLog logger)
    |> withRoutes appRouter

covering
main : IO ()
main = do
  application <- buildApp
  _ :: t <- getArgs | [] => runProg (runServerArgs (runApp application) [])
  runProg (runServerArgs (runApp application) t)
