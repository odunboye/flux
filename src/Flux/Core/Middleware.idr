module Flux.Core.Middleware

import public Flux.Core.HTTP
import public Flux.Core.Router
import public Data.SortedMap
import Data.Linear.Ref1
import Data.String

%default total

||| A response body: either a single buffered `ByteString` (the common
||| case - `send`/`sendText`/`sendJSON` all produce this), or a stream to
||| write out chunk-by-chunk. `Streamed (Just n) body` claims a known
||| Content-Length of `n` bytes; `Streamed Nothing body` means the length
||| isn't known upfront, so `render` chunk-transfer-encodes it instead
||| (see `Flux.Core.HTTP.chunkEncode`).
public export
data ResponseBody = Buffered ByteString | Streamed (Maybe Nat) (HTTPStream ByteString)

||| A cookie to set on the response. Lives here (rather than in
||| `Flux.Middleware.Cookies`, which builds on this) because `Context`
||| needs it: HTTP allows several `Set-Cookie` headers on one response,
||| which `respHeaders : SortedMap String String` (one value per key)
||| can't represent, so cookies get their own list instead. Build one with
||| `cookie` (sensible defaults) rather than the constructor directly.
public export
record SetCookie where
  constructor MkSetCookie
  name     : String
  value    : String
  path     : String
  maxAge   : Maybe Integer
  httpOnly : Bool
  secure   : Bool

||| A cookie with sensible defaults: root path, HttpOnly, no Max-Age (a
||| session cookie, cleared when the browser closes), not Secure (set
||| `{ secure := True } (cookie n v)` explicitly when serving over TLS).
export
cookie : String -> String -> SetCookie
cookie name value = MkSetCookie name value "/" Nothing True False

export
renderSetCookie : SetCookie -> String
renderSetCookie c =
  let base      := "\{c.name}=\{c.value}; Path=\{c.path}"
      withAge   := maybe base (\ms => base ++ "; Max-Age=\{show ms}") c.maxAge
      withHttp  := if c.httpOnly then withAge ++ "; HttpOnly" else withAge
      withSecure := if c.secure then withHttp ++ "; Secure" else withHttp
   in withSecure

||| Tracks, across one request's entire before/dispatch/after pipeline,
||| whether anything ran `readBody` and what that means for the
||| connection afterward - see `readBody`'s doc comment for why this has
||| to live outside `Context` proper (as a mutable cell `Context` merely
||| carries a reference to) rather than as an ordinary field threaded
||| through return values.
public export
data BodyReadState = Untouched | Consumed (HTTPStream ByteString) | Unsafe

-- Request plus everything a handler/middleware chain needs to build a
-- response: matched path params, arbitrary per-request state, and the
-- response being assembled (status, headers, cookies, body). `bodyRef`
-- is `Nothing` for any `Context` built outside `runApp` (e.g. directly
-- in a test); `runApp` always supplies one - see `readBody`.
public export
record Context where
  constructor MkContext
  request     : Request
  pathParams  : PathParams
  state       : SortedMap String String
  statusCode  : Nat
  respHeaders : SortedMap String String
  respCookies : List SetCookie
  respBody    : ResponseBody
  bodyRef     : Maybe (Ref World BodyReadState)

export
emptyContext : Request -> Context
emptyContext req = MkContext req emptyParams empty 200 empty [] (Buffered (fromString "")) Nothing

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
addCookie : SetCookie -> Context -> Context
addCookie c ctx = { respCookies $= (c ::) } ctx

export
send : ByteString -> Context -> Context
send body ctx = { respBody := Buffered body } ctx

export
sendText : String -> Context -> Context
sendText str = setHeader "Content-Type" "text/plain" . send (fromString str)

||| Streams a response body instead of buffering it - see `ResponseBody`.
export
sendStream : Maybe Nat -> HTTPStream ByteString -> Context -> Context
sendStream len body ctx = { respBody := Streamed len body } ctx

cookieHeaders : Context -> List (String, String)
cookieHeaders ctx = map (\c => ("Set-Cookie", renderSetCookie c)) ctx.respCookies

-- Assemble the final context into an emitting HTTP wire response: the
-- status line and headers as one emission, followed by the (possibly
-- chunk-encoded) body.
export
render : Context -> HTTPStream ByteString
render ctx =
  case ctx.respBody of
    Buffered body =>
      let hs := toList ctx.respHeaders ++ cookieHeaders ctx ++ [("Content-Length", show (length body))]
       in emit (fastConcat [encodeResponse ctx.statusCode hs, body])
    Streamed (Just len) body =>
      let hs := toList ctx.respHeaders ++ cookieHeaders ctx ++ [("Content-Length", show len)]
       in emit (encodeResponse ctx.statusCode hs) >> body
    Streamed Nothing body =>
      let hs := toList ctx.respHeaders ++ cookieHeaders ctx ++ [("Transfer-Encoding", "chunked")]
       in emit (encodeResponse ctx.statusCode hs) >> chunkEncode body

||| An application-level failure a handler wants rendered directly, e.g.
||| `throw (MkAppError 404 "user not found")`. Caught and rendered by
||| `runApp` (see `ErrorRenderer`/`App.onError`) rather than propagating.
public export
record AppError where
  constructor MkAppError
  status  : Nat
  message : String

||| The effect handlers and middleware run in: real IO (via `liftIO`) plus
||| the ability to fail with a typed `AppError`. Deliberately separate from
||| the HTTP-wire-level `HTTPProg`/`HTTPErr` (`Flux.Core.HTTP`) - app code
||| shouldn't need to think about request-parsing errors.
public export
0 AppProg : Type -> Type
AppProg = Async Poll [Errno,AppError]

-- Handlers and middleware share a shape: given a `Context`, they may
-- perform IO (via `liftIO`), fail with an `AppError`, and produce an
-- updated `Context`.
public export
0 Handler : Type
Handler = Context -> AppProg Context

public export
0 Middleware : Type
Middleware = Context -> AppProg Context

-- Run a chain of middleware/handlers in sequence, threading the context through.
export
runChain : List Middleware -> Context -> AppProg Context
runChain []        ctx = pure ctx
runChain (m :: ms) ctx = m ctx >>= runChain ms

--------------------------------------------------------------------------------
-- Reading a request body
--------------------------------------------------------------------------------

public export
data BodyError = BodyTooLarge | BodyMalformed | BodyIOError

-- HTTPErr's three constructors plus Errno, mapped onto BodyError.
-- HeaderSizeExceeded/InvalidRequest shouldn't actually occur reading a
-- body (they're wire-parsing errors from earlier in the request), but
-- HTTPErr is shared with parsing, so this handles them (as BodyMalformed)
-- rather than assert_total-ing past them.
mapBodyErr : HSum [Errno,HTTPErr] -> BodyError
mapBodyErr (Here _)                           = BodyIOError
mapBodyErr (There (Here ContentSizeExceeded)) = BodyTooLarge
mapBodyErr (There (Here _))                   = BodyMalformed

||| Reads and fully collects a `Handler`'s request body (up to `maxBytes`),
||| returning `Left BodyTooLarge` if it exceeds that, or `Left BodyMalformed`/
||| `Left BodyIOError` for a lower-level failure while reading it.
|||
||| **A failed read forces the connection closed after this response** -
||| `runApp` will report `CloseAfterResponse` (see `Flux.Core.HTTP.BodyOutcome`)
||| regardless of what the `Handler` does afterward, even if it goes on to
||| return an otherwise-ordinary `Context`. This isn't a policy choice, it's
||| forced by what the underlying library can express: once a bounded read
||| over the body aborts partway through, there is no continuation that
||| safely resumes parsing the next pipelined request from wherever the wire
||| position was left - the position is genuinely, unrecoverably lost.
|||
||| A *successful* read does **not** force the connection closed - the
||| connection stays alive for further pipelined requests using the real
||| continuation past the body, not the stale, already-partially-consumed
||| `Context.request.body` value (reusing that directly, e.g. via
||| `Flux.Core.HTTP.respondWith`'s ordinary `drain`, would silently reissue
||| live socket reads from wherever the connection cursor happens to sit,
||| not replay anything - so it never happens once a `Handler` has read the
||| body).
|||
||| This all needs a side-effecting cell (`Context.bodyRef`) rather than an
||| ordinary `Context` field, because `runApp` resets to a *fresh* `Context`
||| whenever anything throws (see its doc comment) - a plain field recording
||| "the body was read" would be silently discarded by exactly the case that
||| matters (a `Handler` reads the body successfully, then something else it
||| does afterward throws an unrelated `AppError`). A mutable cell, once
||| written, survives that reset; `runApp` reads it once, after the whole
||| pipeline has resolved either way.
export covering
readBody : (maxBytes : Nat) -> Context -> AppProg (Either BodyError ByteString)
readBody maxBytes ctx = do
  let bounded = C.limit ContentSizeExceeded maxBytes ctx.request.body
  outcome <- weakenErrors (pull (foldPair (:<) [<] bounded))
  case outcome of
    Succeeded (sb,cont) => do
      maybe (pure ()) (\r => writeref r (Consumed cont)) ctx.bodyRef
      pure (Right (fastConcat (sb <>> [])))
    Error errs => do
      maybe (pure ()) (\r => writeref r Unsafe) ctx.bodyRef
      pure (Left (mapBodyErr errs))
    Canceled => do
      maybe (pure ()) (\r => writeref r Unsafe) ctx.bodyRef
      pure (Left BodyIOError)

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

||| Renders a caught `AppError` onto a (fresh) `Context`. Plugged into
||| `App.onError`; see `defaultErrorRenderer` and `Flux.Data.JSON.jsonErrorRenderer`.
public export
0 ErrorRenderer : Type
ErrorRenderer = AppError -> Context -> Context

export
defaultErrorRenderer : ErrorRenderer
defaultErrorRenderer err ctx = setStatus err.status (sendText err.message ctx)

||| `before` middleware runs (in order) ahead of the matched handler and can
||| short-circuit nothing yet, only annotate the context; `after` middleware
||| runs once the handler (or the 404 fallback) has produced a response, so
||| it can see the final status code/body (e.g. to log or time the request).
||| `onError` renders any `AppError` thrown by before/dispatch/after into a
||| response (see `runApp`).
public export
record App where
  constructor MkApp
  router  : Router Handler
  before  : List Middleware
  after   : List Middleware
  onError : ErrorRenderer

export
emptyApp : App
emptyApp = MkApp empty [] [] defaultErrorRenderer

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

export
withErrorRenderer : ErrorRenderer -> App -> App
withErrorRenderer r a = { onError := r } a

notFound : Context -> Context
notFound ctx = setStatus 404 (send (fromString "Not Found") ctx)

methodNotAllowed : List Method -> Context -> Context
methodNotAllowed methods ctx =
  setHeader "Allow" (joinBy ", " (map show methods)) $
  setStatus 405 (send (fromString "Method Not Allowed") ctx)

dispatch : Router Handler -> Context -> AppProg Context
dispatch router ctx =
  case matchRoute ctx.request.method ctx.request.uri router of
    Matched params handler => handler ({ pathParams := params } ctx)
    WrongMethod methods    => pure (methodNotAllowed methods ctx)
    NoMatch                => pure (notFound ctx)

internalServerError : ErrorRenderer -> Context -> Context
internalServerError onError = onError (MkAppError 500 "Internal Server Error")

-- Run the full application for one request: before-middleware, route
-- dispatch (or 404/405), after-middleware, then render to wire bytes.
-- Any AppError thrown along the way is caught here and rendered via
-- `onError`; any other failure (e.g. an unexpected IO error from a
-- handler) is caught too and rendered as a generic 500, rather than
-- propagating out and silently dropping the connection with no response.
-- Both cases necessarily render onto a *fresh* Context (just the original
-- request) since a caught failure discards whatever the before-chain had
-- already accumulated onto the Context up to that point.
--
-- `bref` (a fresh `BodyReadState` cell, one per request) is created here
-- and handed to every Context in the pipeline via `bodyRef` so `readBody`
-- can reach it; it's read *after* the handleErrors above resolves, not
-- through whichever Context comes out of it - a mutable cell is what lets
-- "a Handler successfully read the body, then something unrelated threw"
-- still report the real continuation instead of losing it to the reset
-- above (see `readBody`'s doc comment).
export covering
runApp : App -> Responder
runApp (MkApp router before after onError) req = Prelude.do
  (ctx, st) <- exec $ Prelude.do
    bref <- newref Untouched
    let start := { bodyRef := Just bref } (emptyContext req)
    result <- handleErrors
      (\case
        Here _         => pure $ internalServerError onError (emptyContext req)
        There (Here e) => pure $ onError e (emptyContext req))
      (Prelude.do
        ctx0 <- runChain before start
        ctx1 <- dispatch router ctx0
        runChain after ctx1)
    st <- readref bref
    pure (result, st)
  render ctx
  case st of
    -- Nothing touched the body - drain it here, exactly as `respondWith`
    -- unconditionally used to, to find the real leftover continuation.
    Untouched  => map ContinueWith (drain req.body)
    Consumed c => pure (ContinueWith c)
    Unsafe     => pure CloseAfterResponse
