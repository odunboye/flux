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

-- Strips characters that would break Set-Cookie's own "name=value;
-- attr=val; ..." grammar if they appeared in a cookie's name, value, or
-- path - ";" ends the current attribute early (letting a value like
-- "x; Secure=false" inject a bogus attribute), "\r"/"\n" would inject an
-- entire extra header line. A raw incoming request header can never
-- carry an embedded ";"-abusing or CR/LF-carrying value that reaches
-- here undetected (nothing here decodes wire bytes into this record),
-- but `cookie`/`SetCookie`'s fields are ordinary `String`s an app can
-- populate from anywhere (an echoed value, a upstream API response,
-- ...) - sanitized here, at the single point every `SetCookie` actually
-- gets rendered to wire bytes, rather than only at construction (a
-- record update after `cookie` would otherwise bypass that).
sanitizeCookiePart : String -> String
sanitizeCookiePart = pack . filter (\c => c /= ';' && c /= '\r' && c /= '\n') . unpack

export
renderSetCookie : SetCookie -> String
renderSetCookie c =
  let name      := sanitizeCookiePart c.name
      value     := sanitizeCookiePart c.value
      path      := sanitizeCookiePart c.path
      base      := "\{name}=\{value}; Path=\{path}"
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

-- Strips CR/LF from a header value before it's stored - a raw incoming
-- request header can never carry one through to here (the wire parser
-- splits headers on "\r\n" before values are ever extracted), but
-- `setHeader`'s caller controls the value directly, and that value can
-- come from anywhere (echoed user input, an upstream API response, ...)
-- - left in, it would let a handler unintentionally inject an entire
-- extra header line into its own response.
stripCRLF : String -> String
stripCRLF = pack . filter (\c => c /= '\r' && c /= '\n') . unpack

export
setHeader : String -> String -> Context -> Context
setHeader k v ctx = { respHeaders $= insert k (stripCRLF v) } ctx

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

-- Case-insensitively strips any existing Content-Length/Transfer-Encoding/
-- Connection a caller may have set directly (setHeader is a generic
-- setter) so render's own authoritative framing headers are never
-- duplicated alongside ones a handler already tried to set itself.
dropFramingHeaders : List (String, String) -> List (String, String)
dropFramingHeaders =
  filter (\(k,_) => let lk := toLower k in lk /= "content-length" && lk /= "transfer-encoding" && lk /= "connection")

-- The one framing header render's choice of ResponseBody implies -
-- Nothing for a 204/304, which must not carry any (see render's doc),
-- even if the handler used `sendStream Nothing` on some other status.
framingHeader : ResponseBody -> Maybe (String, String)
framingHeader (Buffered body)       = Just ("Content-Length", show (length body))
framingHeader (Streamed (Just l) _) = Just ("Content-Length", show l)
framingHeader (Streamed Nothing _)  = Just ("Transfer-Encoding", "chunked")

||| Assemble the final context into an emitting HTTP wire response: the
||| status line and headers as one emission, followed by the (possibly
||| chunk-encoded) body - except RFC 9112 §6.3 requires suppressing the
||| body outright for a response to a HEAD request or with status 204/304:
||| HEAD still carries the framing header(s) a GET would have (so a client
||| knows what a GET would look like) but no body bytes; 204/304 carry
||| neither, since there's definitionally no body to frame.
|||
||| A suppressed `Streamed` body is still `drain`ed (its bytes discarded,
||| never emitted) rather than simply never touched: a `Streamed` body
||| can carry a resource that needs releasing (e.g.
||| `Flux.Middleware.Static.staticHandler`'s open file descriptor,
||| registered via `resource`/`bracket` *inside* the stream itself) -
||| that cleanup only runs when the stream is actually pulled to
||| completion, so leaving it completely unevaluated on a HEAD/204/304
||| response would leak whatever it holds. `Buffered` never needs this -
||| it's a plain in-memory `ByteString`, nothing to release.
|||
||| `willClose` adds a `Connection: close` header when true - the real
||| decision the caller already made about whether this connection will
||| actually close after this response, not something `render` derives
||| on its own: it depends on more than just the request (a `readBody`
||| failure elsewhere in the pipeline can *also* force a close, via
||| `BodyOutcome`/`CloseAfterResponse`, invisible to `render` from the
||| `Context` alone), and getting it wrong would mean telling the client
||| a connection is persistent while the server silently drops it.
export
render : (willClose : Bool) -> Context -> HTTPStream ByteString
render willClose ctx =
  let noFraming := ctx.statusCode == 204 || ctx.statusCode == 304
      noBody    := noFraming || ctx.request.method == HEAD
      base      := dropFramingHeaders (toList ctx.respHeaders ++ cookieHeaders ctx)
      framing   := the (Maybe (String, String)) (if noFraming then Nothing else framingHeader ctx.respBody)
      connHdr   := the (List (String, String)) (if willClose then [("Connection", "close")] else [])
      hs        := base ++ toList framing ++ connHdr
      head      := encodeResponse ctx.statusCode hs
   in if noBody
        then case ctx.respBody of
               Buffered _      => emit head
               Streamed _ body => emit head >> drain body
        else case ctx.respBody of
               Buffered body       => emit (fastConcat [head, body])
               Streamed (Just _) b => emit head >> b
               Streamed Nothing  b => emit head >> chunkEncode b

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
|||
||| Neither `before` nor `after` run at all for a request that ends up on
||| the error path: `runApp` catches a throw anywhere in the
||| before/dispatch/after chain and renders onto a *fresh* `Context`,
||| discarding whatever `before` had already set - a request that fails
||| partway through loses `before`-set headers (CORS, security headers,
||| request ID) and never reaches `after` at all (so e.g. access logging
||| never runs for it). `always` (see `useAlways`) exists for hooks that
||| must run regardless - it's applied to whichever `Context` is live once
||| the outcome (success or error-rendered) is known, right before the
||| response is rendered to wire bytes.
public export
record App where
  constructor MkApp
  router  : Router Handler
  before  : List Middleware
  after   : List Middleware
  always  : List Middleware
  onError : ErrorRenderer

export
emptyApp : App
emptyApp = MkApp empty [] [] [] defaultErrorRenderer

export
app : App
app = emptyApp

export
use : Middleware -> App -> App
use m a = { before $= (++ [m]) } a

export
useAfter : Middleware -> App -> App
useAfter m a = { after $= (++ [m]) } a

||| Registers a hook that runs on *every* response, success or error alike
||| - unlike `use`/`useAfter`, which only run on the success path (see
||| `App`'s doc comment). Use this for anything a response should never be
||| missing regardless of outcome: CORS/security headers, a request ID,
||| access logging.
export
useAlways : Middleware -> App -> App
useAlways m a = { always $= (++ [m]) } a

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

-- Drains (discarding whatever it emits, sending nothing) a Streamed
-- response body - releasing any resource it holds (e.g.
-- `Flux.Middleware.Static.staticHandler`'s open `Fd`) via the same
-- `resource`/`bracket` cleanup `render` itself relies on, since that
-- cleanup only ever runs as part of actually pulling the stream to
-- completion. Used when a `Context` is about to be discarded entirely
-- (see `runApp`'s error path) rather than rendered normally - `render`
-- can only drain a body it actually gets to see, and a `Context` reset
-- to a fresh one on error never reaches it at all. A `Buffered` body
-- holds no resource, so this is a no-op for it. Whatever the drain
-- itself does (succeeds, errors, gets canceled) doesn't matter here -
-- the connection is getting a fresh error response regardless; this is
-- purely a best-effort release, not a correctness-relevant result.
covering
drainResponseBody : ResponseBody -> AppProg ()
drainResponseBody (Buffered _)      = pure ()
drainResponseBody (Streamed _ body) =
  ignore (the (AppProg (Outcome [Errno,HTTPErr] ())) (weakenErrors (pull (drain body))))

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
-- That discarding is exactly why `after`'s chain is wrapped in its own
-- inner `handleErrors` below: a `Handler` (e.g. `staticHandler`) can
-- succeed and return a `ctx1` holding an already-open resource (wrapped
-- in a `Streamed` body) before something *later* in the same request -
-- an `after` hook, say - throws. Without draining it first, that
-- resource-holding `ctx1` would just be silently replaced by the fresh
-- error `Context` and garbage-collected, never pulled, so its
-- `resource`/`bracket` cleanup would never run - a real fd leak on any
-- request that fails *after* a resource-holding handler succeeds,
-- independent of `render`'s own HEAD/204/304 draining (which only helps
-- for a `Context` that actually reaches `render` normally). The inner
-- catch has `ctx1` directly in scope (ordinary closure capture, no
-- mutable cell needed) - it drains `ctx1`'s body, then re-throws the
-- same error so the outer `handleErrors` still does the actual
-- fresh-context rendering, unchanged. This doesn't help a `Handler`
-- that opens a resource and then throws *before* returning any
-- `Context` at all (nothing here ever sees such a resource to track it)
-- - that remains the handler's own responsibility, same as any other
-- resource-safety concern inside one.
--
-- `always` then runs on whichever Context is now live (the successful one,
-- or the freshly-rendered error one) - see `App`'s doc comment for why
-- this exists. A failure inside an `always` hook itself is logged and
-- swallowed rather than allowed to break the response entirely: these
-- hooks are meant to be response-finalization steps, not another place a
-- request can fail - and unlike the before/dispatch/after failure above,
-- this path never discards `result`, so there's no equivalent leak risk
-- here to guard against.
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
runApp (MkApp router before after always onError) req = Prelude.do
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
        handleErrors
          (\case
            Here x         => drainResponseBody ctx1.respBody >> throw x
            There (Here e) => drainResponseBody ctx1.respBody >> throw e)
          (runChain after ctx1))
    final <- handleErrors
      (\case
        Here _         => do
          liftIO (stderrLn "runApp: an 'always' hook failed (Errno) - response continues without it")
          pure result
        There (Here _) => do
          liftIO (stderrLn "runApp: an 'always' hook failed (AppError) - response continues without it")
          pure result)
      (runChain always result)
    st <- readref bref
    pure (final, st)
  -- The connection closes if the request itself asked not to be kept
  -- alive (shouldKeepAlive) OR a readBody failure elsewhere forced it
  -- (st == Unsafe) - render needs the real, complete answer, not just
  -- the request-only half of it (see render's own doc comment).
  let isUnsafe := case st of
        Unsafe => True
        _      => False
  render (not (shouldKeepAlive req) || isUnsafe) ctx
  case st of
    -- Nothing touched the body - drain it here, exactly as `respondWith`
    -- unconditionally used to, to find the real leftover continuation.
    Untouched  => map ContinueWith (drain req.body)
    Consumed c => pure (ContinueWith c)
    Unsafe     => pure CloseAfterResponse
