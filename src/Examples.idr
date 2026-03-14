module Examples

import HTTP
import Router
import Middleware
import JSON
import Data.SortedMap

%default total

-- Example data types
public export
record User where
  constructor MkUser
  id    : Integer
  name  : String
  email  : String

export partial
ToJSON User where
  toJSON (MkUser id name email) =
    JObject (fromList [
      ("id", toJSON id),
      ("name", toJSON name),
      ("email", toJSON email)
    ])

-- Sample handlers
users : List User
users = [
  MkUser 1 "Alice" "alice@example.com",
  MkUser 2 "Bob" "bob@example.com"
]

-- GET /api/users - List all users
export partial
listUsers : Handler
listUsers req = jsonResponse users

-- GET /health - Health check endpoint
export partial
health : Handler
health req =
  jsonResponse (JObject (fromList [
    ("status", JString "healthy"),
    ("version", JString "0.1.0")
  ]))

-- GET / - Root endpoint
export partial
root : Handler
root req =
  fastConcat [ok [("Content-Type", "text/plain")], fromString "Welcome to Flux!\n"]

-- Build the router
export partial
appRouter : Router
appRouter = empty
  |> get "/" root
  |> get "/health" health
  |> get "/api/users" listUsers

-- Build the full application with middleware
export partial
mkApp : App
mkApp = app
  |> use corsAllowAll
  |> use requestLogger
  |> withRoutes appRouter
