module Middleware

import public HTTP
import public Router
import public Data.SortedMap

%default total

-- Enhanced request with context
public export
record Context where
  constructor MkContext
  request     : Request
  pathParams  : PathParams
  state       : SortedMap String String
  statusCode  : Nat
  respHeaders : SortedMap String String

export
emptyContext : Request -> Context
emptyContext req = MkContext req emptyParams empty 200 empty

export
setState : String -> String -> Context -> Context
setState k v (MkContext req pp st code rh) = MkContext req pp (insert k v st) code rh

export
getState : String -> Context -> Maybe String
getState k (MkContext _ _ st _ _) = lookup k st

export
setStatus : Nat -> Context -> Context
setStatus code (MkContext req pp st _ rh) = MkContext req pp st code rh

export
setHeader : String -> String -> Context -> Context
setHeader k v (MkContext req pp st code rh) = MkContext req pp st code (insert k v rh)

export
setHeaders : List (String, String) -> Context -> Context
setHeaders hs ctx = foldl (\c,(k,v) => setHeader k v c) ctx hs

-- Middleware type: takes context, returns modified context
public export
Middleware : Type
Middleware = Context -> Context

-- Compose middleware
export
compose : List Middleware -> Middleware
compose [] ctx = ctx
compose (m :: ms) ctx = compose ms (m ctx)

-- Built-in middleware

-- CORS middleware
export
cors : List (String, String) -> Middleware
cors headers ctx = setHeaders headers ctx

export
corsAllowAll : Middleware
corsAllowAll = cors [
  ("Access-Control-Allow-Origin", "*"),
  ("Access-Control-Allow-Methods", "GET, POST, OPTIONS"),
  ("Access-Control-Allow-Headers", "Content-Type")
]

-- Logger middleware (basic version)
export
requestLogger : Middleware
requestLogger ctx =
  -- Note: actual logging would go here
  ctx

-- Error handling middleware
export
errorHandler : Middleware
errorHandler ctx = setHeader "X-Content-Type-Options" "nosniff" ctx

-- Security headers
export
secureHeaders : Middleware
secureHeaders ctx = setHeaders [
  ("X-Frame-Options", "DENY"),
  ("X-XSS-Protection", "1; mode=block"),
  ("X-Content-Type-Options", "nosniff")
] ctx

-- Timeout marker (actual timeout handled at connection level)
export
timeout : Nat -> Middleware
timeout _ ctx = ctx

-- Chain middleware with router
public export
record App where
  constructor MkApp
  router     : Router
  middleware : List Middleware

export
emptyApp : App
emptyApp = MkApp empty []

export
use : Middleware -> App -> App
use m (MkApp r mid) = MkApp r (mid ++ [m])

export
useMany : List Middleware -> App -> App
useMany ms (MkApp r mid) = MkApp r (mid ++ ms)

export
withRoutes : Router -> App -> App
withRoutes r (MkApp _ mid) = MkApp r mid

-- Run the application
export
runApp : App -> Request -> ByteString
runApp (MkApp router middleware) req =
  let ctx0 := emptyContext req
      ctx := compose middleware ctx0
      response := handleRouteWithCtx router ctx
   in response

where
  handleRouteWithCtx : Router -> Context -> ByteString
  handleRouteWithCtx router ctx =
    case matchRoute ctx.request.method ctx.request.uri router of
      Just (params, handler) =>
        let ctx' := MkContext ctx.request params ctx.state ctx.statusCode ctx.respHeaders
         in handler ctx.request
      Nothing =>
        fastConcat [encodeResponse 404 [("Content-Length", "9")], fromString "Not Found"]

-- Convenience builders
export
app : App
app = emptyApp

export
middleware : Middleware -> App -> App
middleware = use

export
router : Router -> App -> App
router = withRoutes
