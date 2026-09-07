module Flux.Core.Middleware

import public Flux.Core.HTTP
import public Flux.Core.Router
import public Data.SortedMap
import Data.String

%default total

-- Request plus everything a handler/middleware chain needs to build a
-- response: matched path params, arbitrary per-request state, and the
-- response being assembled (status, headers, body).
public export
record Context where
  constructor MkContext
  request     : Request
  pathParams  : PathParams
  state       : SortedMap String String
  statusCode  : Nat
  respHeaders : SortedMap String String
  respBody    : ByteString

export
emptyContext : Request -> Context
emptyContext req = MkContext req emptyParams empty 200 empty (fromString "")

export
setState : String -> String -> Context -> Context
setState k v ctx = { state $= insert k v } ctx

export
getState : String -> Context -> Maybe String
getState k ctx = lookup k ctx.state

export
setStatus : Nat -> Context -> Context
setStatus code ctx = { statusCode := code } ctx

export
setHeader : String -> String -> Context -> Context
setHeader k v ctx = { respHeaders $= insert k v } ctx

export
setHeaders : List (String, String) -> Context -> Context
setHeaders hs ctx = foldl (\c,(k,v) => setHeader k v c) ctx hs

export
send : ByteString -> Context -> Context
send body ctx = { respBody := body } ctx

export
sendText : String -> Context -> Context
sendText str = setHeader "Content-Type" "text/plain" . send (fromString str)

-- Assemble the final context into a raw HTTP wire response.
export
render : Context -> ByteString
render ctx =
  let hs := toList ctx.respHeaders ++ [("Content-Length", show (length ctx.respBody))]
   in fastConcat [encodeResponse ctx.statusCode hs, ctx.respBody]

-- Handlers and middleware share a shape: given a `Context`, they may
-- perform IO (via `liftIO`) and produce an updated `Context`.
public export
0 Handler : Type
Handler = Context -> HTTPProg Context

public export
0 Middleware : Type
Middleware = Context -> HTTPProg Context

-- Run a chain of middleware/handlers in sequence, threading the context through.
export
runChain : List Middleware -> Context -> HTTPProg Context
runChain []        ctx = pure ctx
runChain (m :: ms) ctx = m ctx >>= runChain ms

--------------------------------------------------------------------------------
-- Built-in middleware
--------------------------------------------------------------------------------

export
cors : List (String, String) -> Middleware
cors headers ctx = pure (setHeaders headers ctx)

export
corsAllowAll : Middleware
corsAllowAll = cors
  [ ("Access-Control-Allow-Origin", "*")
  , ("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
  , ("Access-Control-Allow-Headers", "Content-Type")
  ]

export
secureHeaders : Middleware
secureHeaders ctx = pure $ setHeaders
  [ ("X-Frame-Options", "DENY")
  , ("X-XSS-Protection", "1; mode=block")
  , ("X-Content-Type-Options", "nosniff")
  ] ctx

--------------------------------------------------------------------------------
-- Application: routes plus before/after middleware
--------------------------------------------------------------------------------

||| `before` middleware runs (in order) ahead of the matched handler and can
||| short-circuit nothing yet, only annotate the context; `after` middleware
||| runs once the handler (or the 404 fallback) has produced a response, so
||| it can see the final status code/body (e.g. to log or time the request).
public export
record App where
  constructor MkApp
  router : Router Handler
  before : List Middleware
  after  : List Middleware

export
emptyApp : App
emptyApp = MkApp empty [] []

export
app : App
app = emptyApp

export
use : Middleware -> App -> App
use m a = { before $= (++ [m]) } a

export
useAfter : Middleware -> App -> App
useAfter m a = { after $= (++ [m]) } a

export
withRoutes : Router Handler -> App -> App
withRoutes r a = { router := r } a

notFound : Context -> Context
notFound ctx = setStatus 404 (send (fromString "Not Found") ctx)

methodNotAllowed : List Method -> Context -> Context
methodNotAllowed methods ctx =
  setHeader "Allow" (joinBy ", " (map show methods)) $
  setStatus 405 (send (fromString "Method Not Allowed") ctx)

dispatch : Router Handler -> Context -> HTTPProg Context
dispatch router ctx =
  case matchRoute ctx.request.method ctx.request.uri router of
    Matched params handler => handler ({ pathParams := params } ctx)
    WrongMethod methods    => pure (methodNotAllowed methods ctx)
    NoMatch                => pure (notFound ctx)

-- Run the full application for one request: before-middleware, route
-- dispatch (or 404), after-middleware, then render to wire bytes.
export
runApp : App -> Request -> HTTPProg ByteString
runApp (MkApp router before after) req = Prelude.do
  ctx0 <- runChain before (emptyContext req)
  ctx1 <- dispatch router ctx0
  ctx2 <- runChain after ctx1
  pure (render ctx2)
