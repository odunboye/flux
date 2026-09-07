module Flux.Core.HTTP

import public Data.SortedMap
import public FS.Posix
import public FS.Socket
import Data.List1

import public IO.Async.Loop.Posix

import public System

import Derive.Prelude

%default total
%language ElabReflection

public export
0 Prog : List Type -> Type -> Type
Prog = AsyncStream Poll

export covering
runProg : Prog [Errno] Void -> IO ()
runProg prog = simpleApp $ mpull (handle [stderrLn . interpolate] prog)

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
-- Server driver
--------------------------------------------------------------------------------
-- These combinators turn a request-handling computation (`Request ->
-- HTTPProg ByteString`, allowed to perform IO and other effects) into a
-- running socket server. They are generic over what actually builds the
-- response so a single implementation backs both the router/middleware
-- based `Flux.Core.Middleware.runApp` and simple standalone responders.

export
respondWith : (Request -> HTTPProg ByteString) -> Maybe Request -> HTTPStream ByteString
respondWith f Nothing  = pure ()
respondWith f (Just r) = Prelude.do
  resp <- exec (f r)
  cons resp r.body

export covering
echoWith :
     (Request -> HTTPProg ByteString)
  -> Socket AF_INET
  -> HTTPPull ByteString (Maybe Request)
  -> AsyncStream Poll [Errno] Void
echoWith f cli p =
  extractErr HTTPErr (writeTo cli (p >>= respondWith f)) >>= \case
    Left _   => emit badRequest |> writeTo cli
    Right () => pure ()

export covering
serveWith : (Request -> HTTPProg ByteString) -> Socket AF_INET -> Async Poll [] ()
serveWith f cli =
  flip guarantee (close' cli) $
    mpull $ handleErrors (\(Here x) => stderrLn "\{x}") $
         bytes cli 0xfff
      |> request
      |> echoWith f cli

export covering
runServer : (Request -> HTTPProg ByteString) -> Bits16 -> (n : Nat) -> (0 p : IsSucc n) => Prog [Errno] Void
runServer f port n = foreachPar n (serveWith f) (acceptOn AF_INET SOCK_STREAM (addr port))

||| Parses CLI args of the shape `["server", port, workers]` (falling back
||| to port 8080 with 128 workers) and runs the server. Pass the tail of
||| `getArgs` (i.e. with the program name dropped) as `args`.
export covering
runServerArgs : (Request -> HTTPProg ByteString) -> List String -> Prog [Errno] Void
runServerArgs f ["server", port, n] =
  case cast {to = Nat} n of
    S k => runServer f (cast port) (S k)
    0   => runServer f (cast port) 128
runServerArgs f _ = runServer f 8080 128
