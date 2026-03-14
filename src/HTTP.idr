module HTTP

import public Data.SortedMap
import public FS.Posix
import public FS.Socket

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

public export
0 Headers : Type
Headers = SortedMap String String

public export
data Method = GET | POST | HEAD

export
Eq Method where
  GET == GET = True
  POST == POST = True
  HEAD == HEAD = True
  _ == _ = False

export
Show Method where
  showPrec _ GET = "GET"
  showPrec _ POST = "POST"
  showPrec _ HEAD = "HEAD"

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
  version : Version
  headers : Headers
  length  : Nat
  type    : Maybe String
  body    : HTTPStream ByteString

export
requestMethod : Request -> Method
requestMethod (R m _ _ _ _ _ _) = m

export
requestUri : Request -> String
requestUri (R _ u _ _ _ _ _) = u

MaxHeaderSize : Nat
MaxHeaderSize = 0xffff

MaxContentSize : Nat
MaxContentSize = 0xffff_ffff

%inline
SPACE, COLON : Bits8
SPACE = 32
COLON = 58

method : String -> Either HTTPErr Method
method "GET"  = Right GET
method "POST" = Right POST
method "HEAD" = Right HEAD
method _      = Left InvalidRequest

version : String -> Either HTTPErr Version
version "HTTP/1.0" = Right V10
version "HTTP/1.1" = Right V11
version "HTTP/2.0" = Right V20
version _          = Left InvalidRequest

startLine : ByteString -> Either HTTPErr (Method,String,Version)
startLine bs =
  case toString <$> split SPACE (trim bs) of
    [m,t,v] => [| (\x,y,z => (x,y,z)) (method m) (pure t) (version v) |]
    _       => Left InvalidRequest

headers : Headers -> List ByteString -> Either HTTPErr Headers
headers hs []     = Right hs
headers hs (h::t) =
  case break (COLON ==) h of
    (xs,BS (S k) bv) =>
     let name := toLower (toString xs)
         val  := toString (trim $ tail bv)
      in headers (insert name val hs) t
    _                => Left InvalidRequest

contentLength : Headers -> Nat
contentLength = maybe 0 cast . lookup "content-length"

contentType : Headers -> Maybe String
contentType = lookup "content-type"

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
  when (cl > MaxContentSize) (throw ContentSizeExceeded)
  pure $ Just (R met tgt vrs hs cl ct $ C.take cl body)

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

response : Maybe Request -> HTTPStream ByteString
response Nothing  = pure ()
response (Just r) = cons resp r.body
  where
    resp : ByteString
    resp = case r.type of
      Nothing => hello
      Just t  => ok [("Content-Type",t),("Content-Length",show r.length)]

echo :
     Socket AF_INET
  -> HTTPPull ByteString (Maybe Request)
  -> AsyncStream Poll [Errno] Void
echo cli p =
  extractErr HTTPErr (writeTo cli (p >>= response)) >>= \case
    Left _   => emit badRequest |> writeTo cli
    Right () => pure ()

covering
serve : Socket AF_INET -> Async Poll [] ()
serve cli =
  flip guarantee (close' cli) $
    mpull $ handleErrors (\(Here x) => stderrLn "\{x}") $
         bytes cli 0xfff
      |> request
      |> echo cli

export
addr : Bits16 -> IP4Addr
addr = IP4 [127,0,0,1]

covering
echoSrv : Bits16 -> (n : Nat) -> (0 p : IsSucc n) => Prog [Errno] Void
echoSrv port n =
  foreachPar n serve (acceptOn AF_INET SOCK_STREAM (addr port))

covering
prog : List String -> Prog [Errno] Void
prog ["server", port, n] =
  case cast {to = Nat} n of
    S k => echoSrv (cast port) (S k)
    0   => echoSrv (cast port) 128
prog _ = echoSrv 2222 128

covering
main : IO ()
main = do
  _ :: t <- getArgs | [] => runProg (prog [])
  runProg (prog t)
