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
%foreign "javascript:lambda: (method, url, headersJson, body, hasBody, onDone, _w) => { const opts = { method: method, headers: JSON.parse(headersJson) }; if (hasBody !== 0) { opts.body = body; } fetch(url, opts).then(function(r){ return r.text().then(function(t){ onDone(r.status)(t)(0); }); }).catch(function(e){ onDone(-1)(String(e))(0); }); }"
prim_fetch : String -> String -> String -> String -> Int -> (Int -> String -> IO ()) -> PrimIO ()

runFetch : HttpRequest -> (Either HttpError HttpResponse -> IO ()) -> IO ()
runFetch req deliver =
  let headersJson       = headersToJson req.headers
      (body, hasBody)   = case req.body of
                             Nothing => ("", 0)
                             Just b  => (b, 1)
      onDone : Int -> String -> IO ()
      onDone status respBody =
        deliver $
          if status < 0
             then Left (NetworkError respBody)
             else if status >= 200 && status < 300
                    then Right (MkResponse status [] respBody)
                    else Left (BadStatus status respBody)
  in primIO (prim_fetch (methodStr req.method) req.url headersJson body hasBody onDone)

-- ─── Public Cmd constructors ─────────────────────────────────────────────────

||| Send an HTTP request via the browser's `fetch()`; result delivered
||| asynchronously through the Web runtime's own dispatch loop, same as
||| any other `msg`.
public export
request : HttpRequest -> (Either HttpError HttpResponse -> msg) -> Cmd msg
request req toMsg = StreamTask (\send => runFetch req (send . toMsg))

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
