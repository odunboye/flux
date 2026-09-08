module Flux.Core.HTTP

import public Data.SortedMap
import public FS.Posix
import public FS.Socket
import Data.List1

import public IO.Async.Loop.Posix
import IO.Async.Loop.Poller
import IO.Async.Signal

import public System
import System.File

import Derive.Prelude

%default total
%language ElabReflection

public export
0 Prog : List Type -> Type -> Type
Prog = AsyncStream Poll

||| Runs the second stream (typically an accept loop) until any of the
||| given signals arrives, then lets it terminate normally rather than
||| erroring. `Flux.Core.HTTP.runProg` blocks these signals at the process
||| level so they reach here instead of killing the process outright.
|||
||| `runServer` wraps its accept loop in `shutdownOn [SIGINT, SIGTERM]`: no
||| new connections are accepted once a signal arrives, but connections
||| already in flight are allowed to finish (`foreachPar`'s internal
||| semaphore-drain guarantees this - see the `async`/`streams` library's
||| `finally`/`guaranteeCase` semantics) before the process exits.
|||
||| PLATFORM NOTE: this relies on `async-posix`'s `awaitSignals`, which
||| calls the POSIX.1b `sigwaitinfo()` syscall. That syscall does not
||| exist on macOS/Darwin - the `posix` package's own C support explicitly
||| excludes it there (`#ifndef __APPLE__` around `li_sigwaitinfo` in
||| `idris2-linux/posix/support/posix.c`) - so on macOS, sending SIGINT or
||| SIGTERM to a running Flux server crashes it
||| (`Exception in foreign-procedure: no entry for "li_sigwaitinfo"`)
||| instead of shutting it down cleanly. This is a pre-existing limitation
||| of the dependency stack, not specific to `shutdownOn` - the same crash
||| already happened with plain SIGINT before this function existed, via
||| `simpleApp`'s built-in handling. Signal-based shutdown only works on
||| Linux; verify it there, not on macOS.
export
shutdownOn : List Signal -> Prog [Errno] o -> Prog [Errno] o
shutdownOn sigs = haltOn (eval (awaitSignals sigs))

||| Runs a `Prog`, blocking SIGINT/SIGTERM at the process level so
||| `shutdownOn` can react to them instead of the OS killing the process
||| immediately. See `shutdownOn`'s platform note: this only works on Linux.
export covering
runProg : Prog [Errno] Void -> IO ()
runProg prog = do
  n <- asyncThreads
  app n [SIGINT, SIGTERM] posixPoller (mpull (handle [stderrLn . interpolate] prog))

public export
data HTTPErr : Type where
  HeaderSizeExceeded  : HTTPErr
  ContentSizeExceeded : HTTPErr
  InvalidRequest      : HTTPErr

%runElab derive "HTTPErr" [Show,Eq,Ord]

export
Interpolation HTTPErr where
  interpolate HeaderSizeExceeded  = "header size exceeded"
  interpolate ContentSizeExceeded = "content size exceeded"
  interpolate InvalidRequest      = "invalid HTTP request"

public export
0 HTTPPull : Type -> Type -> Type
HTTPPull o r = AsyncPull Poll o [Errno,HTTPErr] r

public export
0 HTTPStream : Type -> Type
HTTPStream o = AsyncPull Poll o [Errno,HTTPErr] ()

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
  body    : HTTPStream ByteString

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

export
headers : Headers -> List ByteString -> Either HTTPErr Headers
headers hs []     = Right hs
headers hs (h::t) =
  case break (COLON ==) h of
    (xs,BS (S k) bv) =>
     let name := toLower (toString xs)
         val  := toString (trim $ tail bv)
      in headers (insert name val hs) t
    _                => Left InvalidRequest

export
contentLength : Headers -> Nat
contentLength = maybe 0 cast . lookup "content-length"

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

export
parseQuery : String -> SortedMap String String
parseQuery ""  = empty
parseQuery qs  = foldl insertPair empty (forget (split (== '&') qs))
  where
    insertPair : SortedMap String String -> String -> SortedMap String String
    insertPair acc kv = case break (== '=') kv of
      (k, v) => case strUncons v of
        Just (_, val) => insert k val acc
        Nothing       => insert k "" acc

export
assemble :
     HTTPPull (List ByteString) (HTTPStream ByteString)
  -> HTTPPull o (Maybe Request)
assemble p = Prelude.do
  Right (h,rem) <- C.uncons p | _ => pure Nothing
  (met,tgt,vrs) <- injectEither (startLine h)
  (hs,body)     <- foldPairE headers empty rem
  let cl := contentLength hs
      ct := contentType hs
      (path,qs) := splitQuery tgt
      qmap := parseQuery qs
  when (cl > MaxContentSize) (throw ContentSizeExceeded)
  pure $ Just (R met path qmap vrs hs cl ct $ C.take cl body)

export
request : HTTPStream ByteString -> HTTPPull o (Maybe Request)
request req =
     breakAtSubstring pure "\r\n\r\n" req
  |> C.limit HeaderSizeExceeded MaxHeaderSize
  |> lines
  |> assemble

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

export
addr : Bits16 -> IP4Addr
addr = IP4 [127,0,0,1]

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
chunkEncode : HTTPStream ByteString -> HTTPStream ByteString
chunkEncode = scanFull () (\_,bs => (Just (chunkFrame bs), ())) (const (Just chunkTerminator))

--------------------------------------------------------------------------------
-- Server driver
--------------------------------------------------------------------------------
-- These combinators turn a request-handling computation into a running
-- socket server. A `Responder` builds the *entire* wire response itself
-- (status line, headers, and body, however many chunks that takes) - it's
-- generic over what actually builds the response so a single
-- implementation backs both the router/middleware based
-- `Flux.Core.Middleware.runApp` and simple standalone responders.
public export
0 Responder : Type
Responder = Request -> HTTPStream ByteString

export
respondWith : Responder -> Maybe Request -> HTTPStream ByteString
respondWith f Nothing  = pure ()
respondWith f (Just r) = f r

export covering
echoWith :
     Responder
  -> Socket AF_INET
  -> HTTPPull ByteString (Maybe Request)
  -> AsyncStream Poll [Errno] Void
echoWith f cli p =
  extractErr HTTPErr (writeTo cli (p >>= respondWith f)) >>= \case
    Left _   => emit badRequest |> writeTo cli
    Right () => pure ()

export covering
serveWith : Responder -> Socket AF_INET -> Async Poll [] ()
serveWith f cli =
  flip guarantee (close' cli) $
    mpull $ handleErrors (\(Here x) => stderrLn "\{x}") $
         bytes cli 0xfff
      |> request
      |> echoWith f cli

export covering
runServer : Responder -> Bits16 -> (n : Nat) -> (0 p : IsSucc n) => Prog [Errno] Void
runServer f port n = Prelude.do
  liftIO $ do
    putStrLn "Flux server listening on http://127.0.0.1:\{show port} (\{show n} workers)"
    -- Without this, stdout is fully block-buffered whenever it's not a
    -- TTY (e.g. redirected to a log file), so this message wouldn't
    -- actually appear until the process exits.
    fflush stdout
  shutdownOn [SIGINT, SIGTERM] $
    foreachPar n (serveWith f) (acceptOn AF_INET SOCK_STREAM (addr port))

||| Parses CLI args of the shape `[port, workers]` (falling back to port
||| 8080 with 128 workers for any other shape, including no args at all)
||| and runs the server. Pass the tail of `getArgs` (i.e. with the program
||| name dropped) as `args`.
export covering
runServerArgs : Responder -> List String -> Prog [Errno] Void
runServerArgs f [port, n] =
  case cast {to = Nat} n of
    S k => runServer f (cast port) (S k)
    0   => runServer f (cast port) 128
runServerArgs f _ = runServer f 8080 128
