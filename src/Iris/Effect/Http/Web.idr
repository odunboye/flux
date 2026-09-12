||| Iris.Effect.Http.Web
||| Browser HTTP client effect - backed by `fetch()`, for the Web/DOM
||| backend specifically.
|||
||| `Iris.Effect.Http` (curl via `popen`) only works on native targets
||| (TUI/Desktop compiled by the Chez backend) - `System.File`/`popen`
||| have no meaning once compiled to JS and run in a browser, and even if
||| they did, blocking the browser's single thread on a subprocess isn't
||| an option. `fetch()` is the browser's own async HTTP primitive, so
||| this is a genuinely different implementation, not a thin wrapper over
||| the native one - it shares `Iris.Effect.Http`'s `Method`/
||| `HttpRequest`/`HttpResponse`/`HttpError` types (so `Todo.Api`-style
||| call sites read the same regardless of which effect module a
||| particular backend's entry point imports) but not its `runRequest`.
|||
||| `Cmd`'s `Task : IO msg -> Cmd msg` constructor is unsuitable here:
||| every backend's `execCmd` runs a `Task`'s `IO msg` action and
||| immediately calls `send` on its result (`io >>= send` - see
||| `Iris.Backend.Web.DOM.Run.execCmd`), i.e. it assumes the action
||| already has its result the moment it returns. `fetch()` is
||| Promise-based - there is no synchronous `IO HttpResponse` that
||| doesn't either block the browser's one thread (unavailable; sync XHR
||| is deprecated and disabled in many contexts anyway) or lie about
||| having a result it doesn't have yet. `StreamTask : ((msg -> IO ()) ->
||| IO ()) -> Cmd msg` already has the right shape for a one-shot async
||| result, though - `execCmd (StreamTask act) send _ = act send` just
||| hands the runtime's own `send` callback to `act` and returns
||| immediately; nothing requires `act` to call it before returning, or
||| to call it more than once. `request` below calls it exactly once,
||| whenever the underlying `fetch()` promise actually settles.
module Iris.Effect.Http.Web

import Data.IORef
import Iris.State.TEA
import Iris.Effect.Http

%default covering

-- ─── JSON-encode a header list ────────────────────────────────────────────

-- Minimal JSON string escaping - headers are app-controlled key/value
-- pairs (e.g. "Content-Type"/"application/json"), not attacker input,
-- but escaping `"`/`\` (and control characters that would otherwise
-- produce invalid JSON `JSON.parse` rejects outright) costs nothing and
-- means a header value can never break out of its own string literal.
jsonEscape : String -> String
jsonEscape = pack . concatMap esc . unpack
  where
    esc : Char -> List Char
    esc '"'  = ['\\', '"']
    esc '\\' = ['\\', '\\']
    esc '\n' = ['\\', 'n']
    esc '\r' = ['\\', 'r']
    esc '\t' = ['\\', 't']
    esc c    = [c]

jsonStr : String -> String
jsonStr s = "\"" ++ jsonEscape s ++ "\""

headersToJson : List (String, String) -> String
headersToJson hs = "{" ++ joinComma (map pair hs) ++ "}"
  where
    pair : (String, String) -> String
    pair (k, v) = jsonStr k ++ ":" ++ jsonStr v

    joinComma : List String -> String
    joinComma []        = ""
    joinComma [x]       = x
    joinComma (x :: xs) = x ++ "," ++ joinComma xs

-- ─── fetch() FFI ───────────────────────────────────────────────────────────

-- `onDone` is called exactly once, however the fetch settles: with the
-- real HTTP status and response body text on a completed request
-- (whatever the status - a 404/500 still "succeeds" as far as fetch()
-- itself is concerned, same as curl's exit code in the native effect),
-- or with status -1 and the error's own message if the request never
-- reached a server at all (DNS failure, connection refused, CORS
-- rejection - the one native `Iris.Effect.Http` doesn't have to
-- distinguish, since curl fails the whole process the same way for any
-- of those).
%foreign "javascript:lambda: (method,url,headersJson,body,hasBody,timeoutMs,maxBytes,onDone,_w) => { const controller=new AbortController();let settled=false,timedOut=false;const finish=(status,text)=>{if(settled)return;settled=true;clearTimeout(timer);onDone(status)(text)(0);};const timer=timeoutMs>0?setTimeout(()=>{timedOut=true;controller.abort();},timeoutMs):null;const opts={method,headers:JSON.parse(headersJson),signal:controller.signal};if(hasBody!==0)opts.body=body;fetch(url,opts).then(async r=>{const declared=Number(r.headers.get('content-length')||0);if(maxBytes>0&&declared>maxBytes){controller.abort();finish(-3,String(declared));return;}const text=await r.text();if(maxBytes>0&&new TextEncoder().encode(text).length>maxBytes){finish(-3,String(maxBytes));return;}finish(r.status,text);}).catch(e=>finish(timedOut?-2:(e&&e.name==='AbortError'?-4:-1),String(e)));return controller; }"
prim_fetch : String -> String -> String -> String -> Int -> Int -> Int
          -> (Int -> String -> IO ()) -> PrimIO AnyPtr

%foreign "javascript:lambda: (controller,_w) => { if(controller)controller.abort(); }"
prim_abort : AnyPtr -> PrimIO ()

public export
record FetchOptions where
  constructor MkFetchOptions
  timeoutMs        : Nat
  maxResponseBytes : Nat

public export
defaultFetchOptions : FetchOptions
defaultFetchOptions = MkFetchOptions 30000 10485760

public export
record RetryPolicy where
  constructor MkRetryPolicy
  retries        : Nat
  initialDelayMs : Nat
  maximumDelayMs : Nat

public export
defaultRetryPolicy : RetryPolicy
defaultRetryPolicy = MkRetryPolicy 3 250 4000

public export
retryDelays : RetryPolicy -> List Nat
retryDelays policy = go policy.retries policy.initialDelayMs
  where
    go : Nat -> Nat -> List Nat
    go Z _ = []
    go (S remaining) delay = delay :: go remaining (min policy.maximumDelayMs (delay * 2))

%foreign "javascript:lambda: (delay,action,_w) => setTimeout(()=>action(0),delay)"
prim_scheduleRetry : Int -> IO () -> PrimIO AnyPtr

%foreign "javascript:lambda: (timer,_w) => clearTimeout(timer)"
prim_cancelRetry : AnyPtr -> PrimIO ()

runFetch : FetchOptions -> HttpRequest -> (Either HttpError HttpResponse -> IO ()) -> IO (IO ())
runFetch options req deliver =
  let headersJson       = headersToJson req.headers
      (body, hasBody)   = case req.body of
                             Nothing => ("", 0)
                             Just b  => (b, 1)
      onDone : Int -> String -> IO ()
      onDone status respBody =
        deliver $
          if status == -2 then Left Timeout
          else if status == -3 then Left (ResponseTooLarge options.maxResponseBytes)
          else if status == -4 then Left Cancelled
          else if status < 0
             then Left (NetworkError respBody)
             else if status >= 200 && status < 300
                    then Right (MkResponse status [] respBody)
                    else Left (BadStatus status respBody)
  in do
    controller <- primIO (prim_fetch (methodStr req.method) req.url headersJson body hasBody
      (cast options.timeoutMs) (cast options.maxResponseBytes) onDone)
    pure (primIO (prim_abort controller))

retryable : Either HttpError HttpResponse -> Bool
retryable (Left (NetworkError _)) = True
retryable (Left Timeout) = True
retryable (Left (BadStatus status _)) = status == 429 || status >= 500
retryable _ = False

covering
runFetchWithRetry : FetchOptions -> RetryPolicy -> HttpRequest
                 -> (Either HttpError HttpResponse -> IO ()) -> IO (IO ())
runFetchWithRetry options policy request deliver = do
  stoppedRef <- newIORef False
  cancelRef <- newIORef (pure ())
  let covering attempt : Nat -> Nat -> IO ()
      attempt remaining delay = do
        stopped <- readIORef stoppedRef
        when (not stopped) $ do
          cancel <- runFetch options request (\result => do
            stoppedNow <- readIORef stoppedRef
            case stoppedNow of
              True => pure ()
              False =>
                if retryable result && remaining > 0
                   then do
                     timer <- primIO (prim_scheduleRetry (cast delay)
                       (attempt (remaining `minus` 1)
                         (min policy.maximumDelayMs (delay * 2))))
                     writeIORef cancelRef (primIO (prim_cancelRetry timer))
                   else deliver result)
          writeIORef cancelRef cancel
  attempt policy.retries policy.initialDelayMs
  pure $ do
    writeIORef stoppedRef True
    cancel <- readIORef cancelRef
    cancel

-- ─── Public Cmd constructors ─────────────────────────────────────────────────

||| Send an HTTP request via the browser's `fetch()`; result delivered
||| asynchronously through the Web runtime's own dispatch loop, same as
||| any other `msg`.
public export
requestWith : FetchOptions -> HttpRequest
           -> (Either HttpError HttpResponse -> msg) -> Cmd msg
requestWith options req toMsg =
  CancellableTask (\send => runFetch options req (send . toMsg))

public export
requestWithRetry : FetchOptions -> RetryPolicy -> HttpRequest
                -> (Either HttpError HttpResponse -> msg) -> Cmd msg
requestWithRetry options policy req toMsg =
  CancellableTask (\send => runFetchWithRetry options policy req (send . toMsg))

public export
request : HttpRequest -> (Either HttpError HttpResponse -> msg) -> Cmd msg
request req toMsg = requestWith defaultFetchOptions req toMsg

public export
get : String -> (Either HttpError HttpResponse -> msg) -> Cmd msg
get url = Iris.Effect.Http.Web.request (MkRequest GET url [] Nothing)

public export
post : String -> List (String, String) -> String
     -> (Either HttpError HttpResponse -> msg) -> Cmd msg
post url hdrs body = Iris.Effect.Http.Web.request (MkRequest POST url hdrs (Just body))

public export
put : String -> List (String, String) -> String
    -> (Either HttpError HttpResponse -> msg) -> Cmd msg
put url hdrs body = Iris.Effect.Http.Web.request (MkRequest PUT url hdrs (Just body))

public export
delete : String -> (Either HttpError HttpResponse -> msg) -> Cmd msg
delete url = Iris.Effect.Http.Web.request (MkRequest DELETE url [] Nothing)
