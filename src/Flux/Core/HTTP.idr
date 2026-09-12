module Flux.Core.HTTP

import public Data.SortedMap
import public Flux.Core.Runtime
import Flux.Async.Server as Server
import Flux.Async.Runner
import Flux.Async.Standalone
import Flux.Async.Socket as Net
import Data.List1
import Data.Linear.Ref1
import Data.String
import Data.Vect

import Flux.Server.Config

import public System
import System.File

import Derive.Prelude

%default total
%language ElabReflection

public export
0 Prog : List Type -> Type -> Type
Prog = AsyncStream Poll

||| Poll process-blocked termination signals without blocking an owner loop.
export covering
fluxAwaitSignals : List Signal -> Task [] ()
fluxAwaitSignals sigs = do
  stopping <- liftIO shutdownRequested
  unless stopping (Flux.Async.Core.sleep 50 >> fluxAwaitSignals sigs)

export
defaultAsyncThreads : IO (Subset Nat IsSucc)
defaultAsyncThreads = do
  setting <- getEnv "FLUX_EVENT_LOOPS"
  pure $ case cast {to = Nat} <$> setting of
    Just (S k) => Element (S k) %search
    _ => Element 2 %search

||| Run background tasks within the program's lifetime. Scope exit joins their
||| finalizers before returning. Servers use separate fixed connection owners.
export covering
runProgWith : List (Async Poll [] ()) -> Prog [Errno] Void -> IO ()
runProgWith background prog = do
  Right () <- startShutdownWatchdog 35000 | Left err => do
    stderrLn ("Flux: " ++ err)
    exitFailure
  result <- runTask $ the (Task [Errno] ()) $ do
    traverse_ (\task => ignore (spawn task)) background
    pullIn prog
  stopShutdownWatchdog
  case result of
    Left err => stderrLn ("Flux runtime: " ++ err) >> exitFailure
    Right (Error (Here err)) => stderrLn "\{err}" >> exitFailure
    _ => pure ()

export covering
runProg : Prog [Errno] Void -> IO ()
runProg = runProgWith []

public export
data HTTPErr : Type where
  HeaderSizeExceeded  : HTTPErr
  ContentSizeExceeded : HTTPErr
  InvalidRequest      : HTTPErr
  TruncatedBody       : HTTPErr

%runElab derive "HTTPErr" [Show,Eq,Ord]

export
Interpolation HTTPErr where
  interpolate HeaderSizeExceeded  = "header size exceeded"
  interpolate ContentSizeExceeded = "content size exceeded"
  interpolate InvalidRequest      = "invalid HTTP request"
  interpolate TruncatedBody       = "truncated request body"

public export
0 HTTPPull : Type -> Type -> Type
HTTPPull o r = AsyncPull Poll o [Errno,HTTPErr] r

public export
0 HTTPStream : Type -> Type
HTTPStream o = AsyncPull Poll o [Errno,HTTPErr] ()

||| A request body: emits up to `length` bytes, and - once exhausted -
||| *results in* the connection's byte stream continuing right after it
||| (whatever the next pipelined request's bytes are, if any). This is
||| deliberately not exposed for `Responder`s/`Handler`s to read directly:
||| the driver (`Flux.Core.HTTP.respondWith`) is the sole, single-pass
||| consumer of a request's body, since it needs that continuation to
||| correctly parse further requests on a persistent connection - draining
||| it (or reading it) a second time independently would read whatever
||| bytes happen to be next on the wire (i.e. corrupt the next request).
public export
0 HTTPBody : Type
HTTPBody = HTTPPull ByteString (HTTPStream ByteString)

||| An effectful computation (parsing, IO, business logic) that doesn't
||| itself stream bytes. Handlers and middleware live in this monad; use
||| `exec` to lift one into an `HTTPPull`/`HTTPStream` pipeline.
public export
0 HTTPProg : Type -> Type
HTTPProg = Async Poll [Errno,HTTPErr]

public export
0 Headers : Type
Headers = SortedMap String String

public export
data Method = GET | POST | HEAD | PUT | DELETE | PATCH | OPTIONS

export
Eq Method where
  GET == GET = True
  POST == POST = True
  HEAD == HEAD = True
  PUT == PUT = True
  DELETE == DELETE = True
  PATCH == PATCH = True
  OPTIONS == OPTIONS = True
  _ == _ = False

export
Show Method where
  showPrec _ GET = "GET"
  showPrec _ POST = "POST"
  showPrec _ HEAD = "HEAD"
  showPrec _ PUT = "PUT"
  showPrec _ DELETE = "DELETE"
  showPrec _ PATCH = "PATCH"
  showPrec _ OPTIONS = "OPTIONS"

public export
data Version = V10 | V11 | V20

export
Eq Version where
  V10 == V10 = True
  V11 == V11 = True
  V20 == V20 = True
  _ == _ = False

public export
record Request where
  constructor R
  method  : Method
  uri     : String
  query   : SortedMap String String
  version : Version
  headers : Headers
  length  : Nat
  type    : Maybe String
  body    : HTTPBody

export
requestMethod : Request -> Method
requestMethod (R m _ _ _ _ _ _ _) = m

export
requestUri : Request -> String
requestUri (R _ u _ _ _ _ _ _) = u

export
requestQuery : Request -> SortedMap String String
requestQuery (R _ _ q _ _ _ _ _) = q

export
getQuery : String -> Request -> Maybe String
getQuery name req = lookup name req.query

MaxHeaderSize : Nat
MaxHeaderSize = 0xffff

MaxContentSize : Nat
MaxContentSize = 0xffff_ffff

%inline
SPACE, COLON : Bits8
SPACE = 32
COLON = 58

export
method : String -> Either HTTPErr Method
method "GET"     = Right GET
method "POST"    = Right POST
method "HEAD"    = Right HEAD
method "PUT"     = Right PUT
method "DELETE"  = Right DELETE
method "PATCH"   = Right PATCH
method "OPTIONS" = Right OPTIONS
method _         = Left InvalidRequest

export
version : String -> Either HTTPErr Version
version "HTTP/1.0" = Right V10
version "HTTP/1.1" = Right V11
version "HTTP/2.0" = Right V20
version _          = Left InvalidRequest

export
startLine : ByteString -> Either HTTPErr (Method,String,Version)
startLine bs =
  case toString <$> split SPACE (trim bs) of
    [m,t,v] => [| (\x,y,z => (x,y,z)) (method m) (pure t) (version v) |]
    _       => Left InvalidRequest

||| Parses one request's headers, folding them into a `Headers` map -
||| except for security-sensitive cases rejected outright rather than silently
||| resolved, all real request-smuggling/confusion shapes behind a proxy
||| that disagrees with this parser (RFC 9112 §5.1/§6.3, §3.2):
||| whitespace between the header name and its colon (a lenient parser
||| would let `Content-Length : 5` and `Content-Length: 5` disagree with
||| each other about whether they're "the same" header - this parser's
||| own map-key lookups would previously treat them as different keys
||| entirely, silently losing the *real* Content-Length to a mangled key
||| `contentLength`/the duplicate check below never finds), a repeated
||| `Content-Length` (a plain `SortedMap.insert` would just keep the
||| last one, silently accepting conflicting framing), any
||| `Transfer-Encoding` at all (chunked request bodies aren't decoded by
||| this parser - treating one as an ordinary, Content-Length-less
||| request would parse it as an empty body and misinterpret the
||| chunked-framed bytes that follow as the start of the next pipelined
||| request), and a repeated `Host` (the same conflicting-framing shape
||| as duplicate Content-Length, and a real cache-poisoning/virtual-host-
||| confusion vector in practice - a *missing* Host on HTTP/1.1 is
||| rejected separately, in `assemble`, once the version is known).
||| Duplicate Authorization is also rejected: intermediaries and applications
||| must not select different credentials from one request.
export
headers : Headers -> List ByteString -> Either HTTPErr Headers
headers hs []     = Right hs
headers hs (h::t) =
  case break (COLON ==) h of
    (xs,BS (S k) bv) =>
     if any isSpace (unpack (toString xs))
       then Left InvalidRequest
       else
         let name := toLower (toString xs)
             val  := toString (trim $ tail bv)
          in case (name, lookup name hs) of
               ("transfer-encoding", _)   => Left InvalidRequest
               ("content-length", Just _) => Left InvalidRequest
               ("host", Just _)           => Left InvalidRequest
               ("authorization", Just _)  => Left InvalidRequest
               _                          => headers (insert name val hs) t
    _                => Left InvalidRequest

||| The declared body length, `Right 0` if there's no `Content-Length`
||| header at all. A present-but-malformed value (anything but a non-empty
||| run of ASCII digits) is rejected rather than silently treated as `0` -
||| an unvalidated cast previously let a garbage value pass as an empty
||| body instead of the parse failing.
export
contentLength : Headers -> Either HTTPErr Nat
contentLength hs = case lookup "content-length" hs of
  Nothing  => Right 0
  Just val => if val /= "" && all isDigit (unpack val)
                then Right (cast val)
                else Left InvalidRequest

export
contentType : Headers -> Maybe String
contentType = lookup "content-type"

-- Splits a request target like "/users?active=true" into ("/users",
-- "active=true"); a target with no "?" yields an empty query part.
export
splitQuery : String -> (String, String)
splitQuery tgt =
  case break (== '?') tgt of
    (path, qs) => case strUncons qs of
      Just (_, rest) => (path, rest)
      Nothing        => (path, "")

hexVal : Char -> Maybe Int
hexVal '0' = Just 0
hexVal '1' = Just 1
hexVal '2' = Just 2
hexVal '3' = Just 3
hexVal '4' = Just 4
hexVal '5' = Just 5
hexVal '6' = Just 6
hexVal '7' = Just 7
hexVal '8' = Just 8
hexVal '9' = Just 9
hexVal 'a' = Just 10
hexVal 'b' = Just 11
hexVal 'c' = Just 12
hexVal 'd' = Just 13
hexVal 'e' = Just 14
hexVal 'f' = Just 15
hexVal 'A' = Just 10
hexVal 'B' = Just 11
hexVal 'C' = Just 12
hexVal 'D' = Just 13
hexVal 'E' = Just 14
hexVal 'F' = Just 15
hexVal _   = Nothing

||| Decodes `%XX` escapes (a URI path segment or query key/value) into
||| the byte they represent. A malformed escape (not two hex digits, or
||| a trailing `%` with fewer than two characters left) is left exactly
||| as-is rather than rejecting the whole request - permissive, matching
||| how most HTTP routers treat a not-quite-valid escape as harmless
||| rather than fatal. Decodes byte-at-a-time (correct for the ASCII
||| range this is overwhelmingly used for, e.g. `%20` for a space) -
||| a multi-byte `%XX%XX` UTF-8 sequence isn't reassembled into a single
||| codepoint.
export
percentDecode : String -> String
percentDecode s = pack (go (unpack s))
  where
    go : List Char -> List Char
    go ('%' :: a :: b :: rest) = case (hexVal a, hexVal b) of
      (Just hi, Just lo) => chr (hi * 16 + lo) :: go rest
      _                  => '%' :: go (a :: b :: rest)
    go (c :: rest) = c :: go rest
    go []          = []

export
parseQuery : String -> SortedMap String String
parseQuery ""  = empty
parseQuery qs  = foldl insertPair empty (forget (split (== '&') qs))
  where
    insertPair : SortedMap String String -> String -> SortedMap String String
    insertPair acc kv = case break (== '=') kv of
      (k, v) => case strUncons v of
        Just (_, val) => insert (percentDecode k) (percentDecode val) acc
        Nothing       => insert (percentDecode k) "" acc

||| Like `C.splitAt`, but treats the underlying pull ending with fewer
||| than `n` elements as a failure (`err`) rather than silently returning
||| whatever was available as if it were the whole thing. `C.splitAt`
||| itself can't distinguish "got exactly n" from "the source had fewer
||| than n and ran out" - both just return an immediately-exhausted
||| continuation - so a client declaring a Content-Length larger than
||| what it actually sends would otherwise have that shortfall silently
||| accepted as a complete, valid body (the request looking done, and
||| whatever the client sends *next* on the same connection - the start
||| of its next request, say - getting misread as more of this one, or
||| vice versa: the same request-smuggling shape as the framing checks
||| in `headers` above). Checked lazily, exactly where `C.splitAt`
||| itself is - the first time something actually pulls far enough into
||| the body to reach the shortfall, not eagerly at parse time (keeping
||| `assemble` itself non-buffering, per `HTTPBody`'s docs).
export
splitAtChecked : Chunk c o => Has e es => Lazy e -> Nat -> Pull f c es r -> Pull f c es (Pull f c es r)
splitAtChecked err 0 p = pure p
splitAtChecked err k p =
  assert_total $ Flux.Stream.Core.uncons p >>= \case
    Left _       => throw err
    Right (vs,q) => case splitChunkAt k vs of
      Middle pre post => cons pre (pure $ cons post q)
      All n            => cons vs (splitAtChecked err n q)

||| Parses one request from the front of `p`. `body` (see `HTTPBody`)
||| emits up to Content-Length bytes and then results in whatever comes
||| after - draining it (the driver's job, exactly once - see `HTTPBody`'s
||| docs) is how a persistent connection finds the start of the next
||| request instead of losing already-buffered bytes to a fresh read.
||| `maxBodySize` bounds Content-Length itself (`ServerConfig.maxBodySize`
||| via `runServerFromConfig`, or `MaxContentSize` via `runServer`) - note
||| this only rejects a request whose *declared* Content-Length exceeds
||| the limit; a `Handler` reading the body itself still separately
||| bounds actual bytes read via `Flux.Core.Middleware.readBody`'s own
||| `maxBytes`.
export
assemble :
     (maxBodySize : Nat)
  -> HTTPPull (List ByteString) (HTTPStream ByteString)
  -> HTTPPull o (Maybe Request)
assemble maxBodySize p = Prelude.do
  Right (h,rem) <- C.uncons p | _ => pure Nothing
  (met,tgt,vrs) <- injectEither (startLine h)
  (hs,body)     <- foldPairE headers empty rem
  cl            <- injectEither (contentLength hs)
  let ct := contentType hs
      (path,qs) := splitQuery tgt
      qmap := parseQuery qs
  -- RFC 9112 §3.2: a server MUST reject an HTTP/1.1 request with no
  -- Host header. HTTP/1.0 predates Host - optional there.
  when (vrs == V11 && lookup "host" hs == Nothing) (throw InvalidRequest)
  when (cl > maxBodySize) (throw ContentSizeExceeded)
  pure $ Just (R met path qmap vrs hs cl ct $ splitAtChecked TruncatedBody cl body)

export
request : (maxBodySize : Nat) -> HTTPStream ByteString -> HTTPPull o (Maybe Request)
request maxBodySize req =
     breakAtSubstring pure "\r\n\r\n" req
  |> C.limit HeaderSizeExceeded MaxHeaderSize
  |> lines
  |> assemble maxBodySize

export
encodeResponse : (status : Nat) -> List (String,String) -> ByteString
encodeResponse status hs =
  fastConcat $ intersperse "\r\n" $ map fromString $
    "HTTP/1.1 \{show status}" ::
    map (\(x,y) => "\{x}: \{y}") hs ++
    ["\r\n"]

export
badRequest : ByteString
badRequest = encodeResponse 400 []

export
ok : List (String,String) -> ByteString
ok = encodeResponse 200

export
hello : ByteString
hello = ok [("Content-Length","0")]

||| `IP4Addr` (`FS.Socket`/`idris2-linux`) is fully general - any four
||| octets, not just loopback. `octets` used to be hardcoded to
||| `[127,0,0,1]` here; `runServer`/`runServerArgs` still pass that
||| explicitly (unchanged behavior), while `runServerFromConfig` passes
||| whatever `parseIPv4` makes of `ServerConfig.host`.
export
addr : (octets : Vect 4 Bits8) -> Bits16 -> IP4Addr
addr octets port = IP4 octets port

showOctets : Vect 4 Bits8 -> String
showOctets [a,b,c,d] = "\{show a}.\{show b}.\{show c}.\{show d}"

||| Parses a plain dotted-quad IPv4 address string ("127.0.0.1", "0.0.0.0")
||| into the four octets `addr`/`IP4Addr` need. No such parser exists
||| anywhere in this project's dependency tree (checked `idris2-linux` and
||| `idris2-streams`) - this is Flux's own, deliberately minimal one: four
||| '.'-separated decimal segments, each `0`-`255`, nothing else (no
||| hostnames, no IPv6, no leading zeros disambiguation beyond what
||| `isDigit`/`cast` already do).
export
parseIPv4 : String -> Maybe (Vect 4 Bits8)
parseIPv4 s = case forget (Data.String.split (== '.') s) of
  [a,b,c,d] => do
    oa <- octet a
    ob <- octet b
    oc <- octet c
    od <- octet d
    Just [oa,ob,oc,od]
  _ => Nothing
  where
    octet : String -> Maybe Bits8
    octet x =
      if x /= "" && all isDigit (unpack x)
        then let n : Integer := cast x
              in if n <= 255 then Just (cast n) else Nothing
        else Nothing

--------------------------------------------------------------------------------
-- Chunked transfer-encoding
--------------------------------------------------------------------------------
-- Frames a stream of response-body `ByteString`s per RFC 7230's chunked
-- transfer-coding: each emitted chunk becomes "<hex length>\r\n<bytes>\r\n",
-- terminated by a final "0\r\n\r\n". Used for streamed response bodies
-- whose total length isn't known upfront (see `Flux.Core.Middleware`'s
-- `ResponseBody`/`sendStream`).

hexDigit : Nat -> Char
hexDigit 0 = '0'
hexDigit 1 = '1'
hexDigit 2 = '2'
hexDigit 3 = '3'
hexDigit 4 = '4'
hexDigit 5 = '5'
hexDigit 6 = '6'
hexDigit 7 = '7'
hexDigit 8 = '8'
hexDigit 9 = '9'
hexDigit 10 = 'a'
hexDigit 11 = 'b'
hexDigit 12 = 'c'
hexDigit 13 = 'd'
hexDigit 14 = 'e'
hexDigit _  = 'f'

export
toHex : Nat -> String
toHex 0 = "0"
toHex n = pack (reverse (go n))
  where
    go : Nat -> List Char
    go 0 = []
    go k = assert_total $ hexDigit (k `mod` 16) :: go (k `div` 16)

chunkFrame : ByteString -> ByteString
chunkFrame bs = fastConcat [fromString (toHex (length bs)), fromString "\r\n", bs, fromString "\r\n"]

chunkTerminator : ByteString
chunkTerminator = fromString "0\r\n\r\n"

export
||| An empty emission is dropped rather than framed: `chunkFrame` on an
||| empty `ByteString` produces exactly `"0\r\n\r\n"` - byte-identical to
||| `chunkTerminator` - so framing one would signal end-of-body to the
||| client mid-stream, with anything emitted afterward becoming
||| unframed trailing bytes.
chunkEncode : HTTPStream ByteString -> HTTPStream ByteString
chunkEncode =
  scanFull () (\_,bs => (if length bs == 0 then Nothing else Just (chunkFrame bs), ()))
    (const (Just chunkTerminator))

--------------------------------------------------------------------------------
-- Server driver
--------------------------------------------------------------------------------
-- These combinators turn a request-handling computation into a running
-- socket server. A `Responder` builds the *entire* wire response itself
-- (status line, headers, and body, however many chunks that takes) - it's
-- generic over what actually builds the response so a single
-- implementation backs both the router/middleware based
-- `Flux.Core.Middleware.runApp` and simple standalone responders.
||| What a `Responder` decides should happen to the connection after it
||| finishes emitting one response: `ContinueWith cont` hands back the byte
||| stream to resume parsing the next pipelined request from (ordinarily
||| just `r.body`, untouched - see `respondWith`); `CloseAfterResponse`
||| means the connection must not be reused, because whatever ran over
||| `r.body` (see `Flux.Core.Middleware.readBody`) failed partway through
||| and left the wire position unrecoverable - there is no continuation
||| that could safely resume parsing from it.
public export
data BodyOutcome = ContinueWith (HTTPStream ByteString) | CloseAfterResponse

public export
0 Responder : Type
Responder = Request -> HTTPPull ByteString BodyOutcome

||| Whether the connection should stay open for another pipelined
||| request after this one, per RFC 9112 §9.3: HTTP/1.1 defaults to
||| persistent unless the client sends `Connection: close`; HTTP/1.0
||| (and anything else, defensively) defaults to closing unless the
||| client explicitly asks to keep it alive.
export
shouldKeepAlive : Request -> Bool
shouldKeepAlive req =
  let conn := map toLower (lookup "connection" req.headers)
   in case req.version of
        V11 => conn /= Just "close"
        _   => conn == Just "keep-alive"

-- Responds to one request via `f`, which reports what to do with the
-- connection afterward (see `BodyOutcome`) - ordinarily `ContinueWith
-- r.body`, the connection's byte stream continuing right after the
-- request just handled. That continuation, not a fresh read off the
-- socket, is what the next loop iteration must parse the next request
-- from: a single `bytes cli n` read can return more than one pipelined
-- request's worth of bytes at once, and only the continuation captured
-- here (rather than a fresh read, which would only ever see whatever
-- arrives *after* that point) preserves the rest of what was already
-- read. Returns whether there was a request at all: False means either
-- the byte source hit EOF (the client closed the connection), `f`
-- reported `CloseAfterResponse`, or the request itself asked not to be
-- kept alive (`shouldKeepAlive`) - any of these signal the caller to
-- stop reading more requests off this connection.
export
respondWith : Responder -> Maybe Request -> HTTPPull ByteString (Bool, HTTPStream ByteString)
respondWith f Nothing  = pure (False, pure ())
respondWith f (Just r) = Prelude.do
  outcome <- f r
  case outcome of
    ContinueWith rest   => pure (shouldKeepAlive r, rest)
    CloseAfterResponse  => pure (False, pure ())

export covering
echoWith :
     Responder
  -> Net.Socket
  -> HTTPPull ByteString (Maybe Request)
  -> AsyncPull Poll Void [Errno] (Bool, HTTPStream ByteString)
echoWith f cli p =
  extractErr HTTPErr (writeTo cli (p >>= respondWith f)) >>= \case
    Left _  => (emit badRequest |> writeTo cli) $> (False, pure ())
    Right b => pure b

-- Reads and responds to one request off `byteStream`, then recurses onto
-- whatever's left of it for the next one - all as a single continuous
-- Pull (rather than looping by re-entering the Async layer via `pullIn`
-- on every iteration, which measured ~10ms of avoidable per-request
-- latency here) - until `echoWith` reports EOF (client closed the
-- connection). `byteStream` must be the connection's one, single,
-- continuously-threaded byte source (see `serveWith`) - not re-created
-- per call, which would silently drop any already-read bytes belonging
-- to a pipelined next request.
--
-- `activity` is "petted" (see `idleTimeout`) after every request that
-- actually completes, so a connection making steady progress is never
-- killed by `serveWith`'s idle timeout no matter how long it's been
-- open - only a connection that stops progressing entirely is.
covering
servePull :
     Responder -> Net.Socket -> Ref World Nat -> (maxBodySize : Nat) -> HTTPStream ByteString
  -> AsyncPull Poll Void [Errno] ()
servePull f cli activity maxBodySize byteStream = Prelude.do
  (continue, rest) <- byteStream |> request maxBodySize |> echoWith f cli
  when continue $ do
    liftIO (mod activity S)
    servePull f cli activity maxBodySize rest

export
idleConnectionTimeout : Clock Duration
idleConnectionTimeout = 60.s

||| Bundles the per-server tuning knobs that used to be hardcoded
||| constants (`MaxContentSize`, `idleConnectionTimeout`) so `runServer`
||| (unchanged, still hardcoded via `defaultLimits`) and
||| `runServerFromConfig` (driven by a real `ServerConfig`) can share the
||| same underlying driver code. `MaxHeaderSize` is deliberately not
||| here - `ServerConfig` has no field for it, so it stays a fixed
||| constant regardless of which entry point is used.
public export
record ServerLimits where
  constructor MkLimits
  maxBodySize     : Nat
  idleConnTimeout : Clock Duration

export
defaultLimits : ServerLimits
defaultLimits = MkLimits MaxContentSize idleConnectionTimeout

||| Watch completed requests; active persistent connections reset the idle bound.
covering
watchIdle : Ref World Nat -> Clock Duration -> Task [] ()
watchIdle activity duration = do
  before <- liftIO (readref activity)
  Flux.Core.Runtime.sleep duration
  after <- liftIO (readref activity)
  unless (before == after) (watchIdle activity duration)

||| Borrows a peer owned by the server supervisor, which joins this task and
||| its children before closing the descriptor.
export covering
serveWith : Responder -> ServerLimits -> Net.Socket -> Task [] ()
serveWith f limits cli = do
  activity <- newref 0
  ignore $ race
    (mpull $ handleErrors (\(Here err) => the (Pull Task Void [] ()) (stderrLn "\{err}")) $
      servePull f cli activity limits.maxBodySize (Flux.Stream.Socket.bytes cli 0xfff))
    (watchIdle activity limits.idleConnTimeout)

covering
runServerAt :
     Responder -> (octets : Vect 4 Bits8) -> Bits16 -> (n : Nat)
  -> (0 p : IsSucc n) => ServerLimits -> Prog [Errno] Void
runServerAt f octets port n limits = exec $ do
  Element owners _ <- liftIO defaultAsyncThreads
  Flux.Async.Core.bracket
    (liftIO (Net.listen (showOctets octets) (cast port) 2048) >>= socketResult)
    (\listener => ignore (Net.close listener))
    (\listener => do
      liftIO $ do
        putStrLn "Flux server listening on http://\{showOctets octets}:\{show port} (\{show owners} event loops, \{show n} connections)"
        fflush stdout
      result <- attempt $ Server.serve owners n 30000 listener
        (serveWith f limits) (fluxAwaitSignals [SIGINT, SIGTERM])
      case result of
        Left (Here err) => liftIO (stderrLn ("Flux: " ++ err)) >> throw EIO
        Right () => pure ())

export covering
runServer : Responder -> Bits16 -> (n : Nat) -> (0 p : IsSucc n) => Prog [Errno] Void
runServer f port n = runServerAt f [127,0,0,1] port n defaultLimits

||| Parses CLI args of the shape `[port, workers]` (falling back to port
||| 8080 with 128 workers for any other shape, including no args at all)
||| and runs the server. Pass the tail of `getArgs` (i.e. with the program
||| name dropped) as `args`. Always binds 127.0.0.1 with `defaultLimits` -
||| see `runServerFromConfig` for a `ServerConfig`-driven equivalent that
||| also honors `host`/`maxBodySize`/`timeout`.
export covering
runServerArgs : Responder -> List String -> Prog [Errno] Void
runServerArgs f [port, n] =
  case cast {to = Nat} n of
    S k => runServer f (cast port) (S k)
    0   => runServer f (cast port) 128
runServerArgs f _ = runServer f 8080 128

||| Converts a millisecond count (as `ServerConfig.timeout` is expressed)
||| into a `Clock Duration`, for `ServerLimits.idleConnTimeout`.
msToDuration : Integer -> Clock Duration
msToDuration ms = makeDuration (ms `div` 1000) ((ms `mod` 1000) * 1_000_000)

||| Like `runServer`, but every tuning knob comes from a real
||| `ServerConfig` (typically `serverConfigFromEnv`) instead of being
||| fixed: `host` (parsed via `parseIPv4` - falls back to `127.0.0.1`
||| with a stderr warning if it doesn't parse, rather than crashing on a
||| config mistake), `port`, `workers` (falling back to 128 the same way
||| `runServerArgs` does for a 0 value - `serveConnections` needs at least one),
||| `maxBodySize`, and `timeout` (converted via `msToDuration`, replacing
||| the fixed `idleConnectionTimeout`). `MaxHeaderSize` is still not
||| configurable - see `ServerLimits`'s doc comment.
export covering
runServerFromConfig : Responder -> ServerConfig -> Prog [Errno] Void
runServerFromConfig f cfg = Prelude.do
  octets <- liftIO $ case parseIPv4 cfg.host of
    Just os => pure os
    Nothing => do
      stderrLn "Flux: could not parse server.host \"\{cfg.host}\" as an IPv4 address, falling back to 127.0.0.1"
      pure [127,0,0,1]
  let limits := MkLimits (cast cfg.maxBodySize) (msToDuration cfg.timeout)
  case cfg.workers of
    S k => runServerAt f octets cfg.port (S k) limits
    0   => runServerAt f octets cfg.port 128 limits
