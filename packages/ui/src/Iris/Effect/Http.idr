||| Iris.Effect.Http
||| HTTP client effect — backed by system curl via popen.
|||
||| Regular requests:   `request`, `get`, `post`
||| Streaming (SSE):    `stream` (for LLM token streaming)
|||
||| Both are wrapped in Cmd so the runtime forks them onto background
||| threads automatically (via Task / StreamTask).
module Iris.Effect.Http

import System.File
import Iris.State.TEA

-- ─── Request / Response ──────────────────────────────────────────────────────

public export
data Method = GET | POST | PUT | PATCH | DELETE | HEAD | OPTIONS

public export
record HttpRequest where
  constructor MkRequest
  method  : Method
  url     : String
  headers : List (String, String)
  body    : Maybe String

public export
record HttpResponse where
  constructor MkResponse
  status  : Int
  headers : List (String, String)
  body    : String

public export
data HttpError
  = NetworkError String
  | Timeout
  | BadStatus Int String
  | BadBody   String
  | Cancelled
  | ResponseTooLarge Nat

-- ─── Stream events ───────────────────────────────────────────────────────────

||| Events emitted by a streaming HTTP request (e.g. SSE from an LLM API).
public export
data StreamEvent
  = ||| A raw data payload (the part after "data: " in SSE).
    Chunk  String
  | ||| The stream ended cleanly.
    Done
  | ||| An error occurred mid-stream.
    StreamError String

-- ─── Local helpers ───────────────────────────────────────────────────────────

-- span/break for lists
httpSpan : (a -> Bool) -> List a -> (List a, List a)
httpSpan _ []        = ([], [])
httpSpan p (x :: xs) =
  if p x then let (ys, zs) = httpSpan p xs in (x :: ys, zs)
         else ([], x :: xs)

httpBreak : (a -> Bool) -> List a -> (List a, List a)
httpBreak p = httpSpan (not . p)

httpDrop : Nat -> List a -> List a
httpDrop Z     xs        = xs
httpDrop _     []        = []
httpDrop (S n) (_ :: xs) = httpDrop n xs

-- join strings with a space between each
httpUnwords : List String -> String
httpUnwords []        = ""
httpUnwords (x :: []) = x
httpUnwords (x :: xs) = x ++ " " ++ httpUnwords xs

export
methodStr : Method -> String
methodStr GET     = "GET"
methodStr POST    = "POST"
methodStr PUT     = "PUT"
methodStr PATCH   = "PATCH"
methodStr DELETE  = "DELETE"
methodStr HEAD    = "HEAD"
methodStr OPTIONS = "OPTIONS"

-- Single-quote-safe shell escaping (wraps in single quotes, escapes ' as '\'')
shellEsc : String -> String
shellEsc s = "'" ++ escape (unpack s) ++ "'"
  where
    escape : List Char -> String
    escape []          = ""
    escape ('\'' :: cs) = "'\\''" ++ escape cs
    escape (c    :: cs) = pack [c] ++ escape cs

headerFlag : (String, String) -> String
headerFlag (k, v) = "-H " ++ shellEsc (k ++ ": " ++ v)

-- Accumulate all lines from a file handle into one string.
covering
readAll : File -> IO String
readAll h = go ""
  where
    covering
    go : String -> IO String
    go acc = do
      eof <- fEOF h
      if eof
        then pure acc
        else do
          Right line <- fGetLine h
            | Left _ => pure acc
          go (acc ++ line)

-- Trim trailing newlines / carriage returns.
trimNL : String -> String
trimNL s = pack (reverse (dropNL (reverse (unpack s))))
  where
    dropNL : List Char -> List Char
    dropNL ('\n' :: cs) = dropNL cs
    dropNL ('\r' :: cs) = dropNL cs
    dropNL cs           = cs

-- Split a string at the last newline.
-- Returns (before, after) where `after` has no newlines.
splitAtLastNL : String -> (String, String)
splitAtLastNL s =
  let chars   = unpack s
      rev     = reverse chars
      (r, l)  = httpBreak (== '\n') rev
      after   = pack (reverse r)
      before  = pack (reverse (httpDrop 1 l))
  in (before, after)

-- ─── Build curl command ───────────────────────────────────────────────────────

-- A per-request-unique, hard-to-guess temp file for `--data @<path>` -
-- fixes a real bug the old fixed `/tmp/iris_http_body.json` path had:
-- every native HTTP `Cmd` runs its curl subprocess on a background
-- thread (`Task`/`StreamTask` - see `Iris.State.TEA`), so two requests
-- in flight at once raced on that ONE shared filename - request B's
-- `writeFile` could overwrite request A's body before A's own curl
-- process got around to reading `@<path>`, sending B's (possibly
-- sensitive) body to A's destination instead. A fixed, predictable
-- path in a world-writable directory is also a symlink risk in its own
-- right, independent of the race - anything able to pre-create
-- `/tmp/iris_http_body.json` as a symlink before this process ever
-- runs could redirect the write.
--
-- Sourced from `/dev/urandom` (via the same `popen` this module already
-- uses for curl itself, rather than a new binary-file-reading path) -
-- unpredictable, and combined with removing the file again right after
-- use (`runRequest`/`runStream`, both exit paths) keeps the exposure
-- window short. NOT a full fix for the symlink risk in the strict
-- sense a real `mkstemp(O_EXCL)` gives (this still separately
-- `writeFile`s to a path chosen in advance, rather than atomically
-- creating-and-opening it in one syscall) - that would need a small C
-- FFI addition (this project's `prebuild` step already compiles one
-- other C file, `c/iristui.c`, so there's precedent) which is a larger
-- change than fits here; unpredictability plus a short, cleaned-up
-- lifetime is what this actually delivers.
covering
randomHex : IO String
randomHex = do
  Right h <- popen "head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n'" Read
    | Left _ => pure "0"
  hex <- readAll h
  ignore (pclose h)
  pure (trimNL hex)

covering
tmpBodyPath : IO String
tmpBodyPath = do
  rand <- randomHex
  pure ("/tmp/iris_http_body_" ++ rand ++ ".json")

-- Write body to a fresh temp file and return the curl data flag plus
-- that file's path (so the caller can remove it once curl is done with
-- it) - `Nothing` for the path when there's no body to write, or the
-- write itself failed (matches the old behavior of silently falling
-- back to no `--data` flag rather than failing the whole request).
covering
writeBody : Maybe String -> IO (String, Maybe String)
writeBody Nothing     = pure ("", Nothing)
writeBody (Just body) = do
  path <- tmpBodyPath
  Right () <- writeFile path body
    | Left _ => pure ("", Nothing)
  pure ("--data @" ++ shellEsc path, Just path)

covering
cleanupBody : Maybe String -> IO ()
cleanupBody Nothing     = pure ()
cleanupBody (Just path) = do
  _ <- removeFile path
  pure ()

covering
buildCmd : HttpRequest -> IO (String, Maybe String)
buildCmd req = do
  (bodyFlag, cleanupPath) <- writeBody req.body
  let method  = "-X " ++ methodStr req.method
      headers = httpUnwords (map headerFlag req.headers)
      url     = shellEsc req.url
      -- append status code on a new line after body
      writeOut = "-w '\\n%{http_code}'"
      silent   = "-s"
  pure (httpUnwords (filter (/= "")
    ["curl", silent, method, headers, bodyFlag, writeOut, url]), cleanupPath)

-- ─── Parse curl output ───────────────────────────────────────────────────────

parseCurlOut : String -> Either HttpError HttpResponse
parseCurlOut raw =
  let (body, statusStr) = splitAtLastNL raw
      statusClean = pack (filter isDigit (unpack statusStr))
      status = cast {to=Int} statusClean
  in if length statusClean /= 3
       then Left (NetworkError ("Bad status line: " ++ statusStr))
       else if status >= 200 && status < 300
         then Right (MkResponse status [] body)
         else Left (BadStatus status body)
  where
    isDigit : Char -> Bool
    isDigit c = c >= '0' && c <= '9'

-- ─── Regular HTTP request ────────────────────────────────────────────────────

covering
runRequest : HttpRequest -> IO (Either HttpError HttpResponse)
runRequest req = do
  (cmd, cleanupPath) <- buildCmd req
  Right h <- popen cmd Read
    | Left e => do
        cleanupBody cleanupPath
        pure (Left (NetworkError (show e)))
  out <- readAll h
  ignore (pclose h)
  cleanupBody cleanupPath
  pure (parseCurlOut out)

-- ─── SSE streaming ───────────────────────────────────────────────────────────

-- Does `s` start with `needle`?
strHasPrefix : (needle : String) -> (haystack : String) -> Bool
strHasPrefix needle haystack =
  let nl = length needle
      hl = length haystack
  in nl <= hl && substr 0 nl haystack == needle

-- Read SSE lines from an open file handle, calling `send` for each data chunk.
covering
readSSE : File -> (StreamEvent -> IO ()) -> IO ()
readSSE h send = do
  eof <- fEOF h
  if eof
    then send Done
    else do
      Right line <- fGetLine h
        | Left _ => send Done
      let l = trimNL line
      if l == "data: [DONE]"
        then send Done
        else do
          when (strHasPrefix "data: " l) $
            send (Chunk (substr 6 (length l `minus` 6) l))
          readSSE h send

covering
runStream : HttpRequest -> (StreamEvent -> IO ()) -> IO ()
runStream req send = do
  (bodyFlag, cleanupPath) <- writeBody req.body
  let method   = "-X " ++ methodStr req.method
      headers  = httpUnwords (map headerFlag req.headers)
      url      = shellEsc req.url
      -- no-buffer so tokens arrive immediately
      flags    = "--no-buffer -s -N"
      cmd      = httpUnwords (filter (/= "")
                   ["curl", flags, method, headers, bodyFlag, url])
  Right h <- popen cmd Read
    | Left e => do
        cleanupBody cleanupPath
        send (StreamError (show e))
  readSSE h send
  ignore (pclose h)
  cleanupBody cleanupPath

-- ─── Public Cmd constructors ─────────────────────────────────────────────────

||| Send an HTTP request; result delivered asynchronously.
public export
covering
request : HttpRequest -> (Either HttpError HttpResponse -> msg) -> Cmd msg
request req toMsg = Task (map toMsg (runRequest req))

public export
covering
get : String -> (Either HttpError HttpResponse -> msg) -> Cmd msg
get url toMsg = request (MkRequest GET url [] Nothing) toMsg

public export
covering
post : String
     -> List (String, String)   -- headers
     -> String                  -- JSON body
     -> (Either HttpError HttpResponse -> msg)
     -> Cmd msg
post url hdrs body toMsg =
  request (MkRequest POST url hdrs (Just body)) toMsg

||| Stream an SSE endpoint; each event is delivered as a msg asynchronously.
||| Typically used for LLM token streaming.
public export
covering
stream : HttpRequest -> (StreamEvent -> msg) -> Cmd msg
stream req toMsg = StreamTask (\send => runStream req (\evt => send (toMsg evt)))
