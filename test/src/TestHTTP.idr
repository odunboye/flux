module TestHTTP

import Flux.Core.HTTP
import Data.SortedMap
import Data.IORef
import System

%default covering

-- method

export
testMethodGet : Bool
testMethodGet = method "GET" == Right GET

export
testMethodAllVariants : Bool
testMethodAllVariants =
  method "POST" == Right POST &&
  method "HEAD" == Right HEAD &&
  method "PUT" == Right PUT &&
  method "DELETE" == Right DELETE &&
  method "PATCH" == Right PATCH &&
  method "OPTIONS" == Right OPTIONS

export
testMethodUnknown : Bool
testMethodUnknown = method "TRACE" == Left InvalidRequest

-- version

export
testVersion11 : Bool
testVersion11 = version "HTTP/1.1" == Right V11

export
testVersionUnknown : Bool
testVersionUnknown = version "FTP/1.0" == Left InvalidRequest

-- startLine

export
testStartLineValid : Bool
testStartLineValid =
  case startLine (fromString "GET /users/42 HTTP/1.1") of
    Right (GET, "/users/42", V11) => True
    _ => False

export
testStartLineWrongArity : Bool
testStartLineWrongArity =
  startLine (fromString "GET /users") == Left InvalidRequest

export
testStartLineBadMethod : Bool
testStartLineBadMethod =
  startLine (fromString "FOO /users HTTP/1.1") == Left InvalidRequest

-- headers

export
testHeadersParse : Bool
testHeadersParse =
  case headers empty [fromString "Content-Type: text/plain", fromString "Content-Length: 5"] of
    Right hs => lookup "content-type" hs == Just "text/plain" &&
                lookup "content-length" hs == Just "5"
    Left _   => False

export
testHeadersLowercasesNames : Bool
testHeadersLowercasesNames =
  case headers empty [fromString "X-Custom-Header: value"] of
    Right hs => lookup "x-custom-header" hs == Just "value"
    Left _   => False

export
testHeadersMalformed : Bool
testHeadersMalformed =
  case headers empty [fromString "NoColonHere"] of
    Left InvalidRequest => True
    _                   => False

export
testHeadersEmpty : Bool
testHeadersEmpty =
  case headers empty [] of
    Right hs => null (SortedMap.toList hs)
    Left _   => False

-- contentLength / contentType

export
testContentLength : Bool
testContentLength = contentLength (fromList [("content-length", "42")]) == 42

export
testContentLengthMissing : Bool
testContentLengthMissing = contentLength empty == 0

export
testContentType : Bool
testContentType = contentType (fromList [("content-type", "application/json")]) == Just "application/json"

-- query string splitting/parsing

export
testSplitQueryPresent : Bool
testSplitQueryPresent = splitQuery "/users?active=true" == ("/users", "active=true")

export
testSplitQueryAbsent : Bool
testSplitQueryAbsent = splitQuery "/users" == ("/users", "")

export
testSplitQueryEmpty : Bool
testSplitQueryEmpty = splitQuery "/users?" == ("/users", "")

export
testParseQuerySingle : Bool
testParseQuerySingle = lookup "active" (parseQuery "active=true") == Just "true"

export
testParseQueryMultiple : Bool
testParseQueryMultiple =
  let q = parseQuery "active=true&limit=10"
   in lookup "active" q == Just "true" && lookup "limit" q == Just "10"

export
testParseQueryNoValue : Bool
testParseQueryNoValue = lookup "flag" (parseQuery "flag") == Just ""

export
testParseQueryEmptyString : Bool
testParseQueryEmptyString = null (SortedMap.toList (parseQuery ""))

-- toHex

export
testToHexSmall : Bool
testToHexSmall = toHex 0 == "0" && toHex 5 == "5" && toHex 15 == "f"

export
testToHexLarge : Bool
testToHexLarge = toHex 16 == "10" && toHex 255 == "ff" && toHex 256 == "100"

-- chunkEncode: runs the real async stream and checks the wire framing.

runStream : HTTPStream ByteString -> IO ByteString
runStream stream = do
  ref <- newIORef []
  runProg $
    handleErrors
      (\case
        Here e         => liftIO (putStrLn "runStream: unexpected Errno: \{e}")
        There (Here e) => liftIO (putStrLn "runStream: unexpected HTTPErr: \{e}"))
      (foreach (\v => liftIO (modifyIORef ref (v ::))) stream)
  chunks <- readIORef ref
  pure (fastConcat (reverse chunks))

export
testChunkEncodeSingle : IO Bool
testChunkEncodeSingle = do
  out <- runStream (chunkEncode (emit (fromString "hello")))
  pure (toString out == "5\r\nhello\r\n0\r\n\r\n")

export
testChunkEncodeMultiple : IO Bool
testChunkEncodeMultiple = do
  out <- runStream (chunkEncode (emit (fromString "hello") >> emit (fromString "world!")))
  pure (toString out == "5\r\nhello\r\n6\r\nworld!\r\n0\r\n\r\n")

export
testChunkEncodeEmpty : IO Bool
testChunkEncodeEmpty = do
  out <- runStream (chunkEncode (pure ()))
  pure (toString out == "0\r\n\r\n")

-- Run all HTTP wire-parser tests (mixing pure and IO-backed cases, since
-- chunk-encoding needs the real async runtime to exercise)
export
runAllTests : IO (List (String, Bool))
runAllTests = do
  chunkSingle   <- testChunkEncodeSingle
  chunkMultiple <- testChunkEncodeMultiple
  chunkEmpty    <- testChunkEncodeEmpty
  pure $
   [ ("methodGet", testMethodGet),
  ("methodAllVariants", testMethodAllVariants),
  ("methodUnknown", testMethodUnknown),
  ("version11", testVersion11),
  ("versionUnknown", testVersionUnknown),
  ("startLineValid", testStartLineValid),
  ("startLineWrongArity", testStartLineWrongArity),
  ("startLineBadMethod", testStartLineBadMethod),
  ("headersParse", testHeadersParse),
  ("headersLowercasesNames", testHeadersLowercasesNames),
  ("headersMalformed", testHeadersMalformed),
  ("headersEmpty", testHeadersEmpty),
  ("contentLength", testContentLength),
  ("contentLengthMissing", testContentLengthMissing),
  ("contentType", testContentType),
  ("splitQueryPresent", testSplitQueryPresent),
  ("splitQueryAbsent", testSplitQueryAbsent),
  ("splitQueryEmpty", testSplitQueryEmpty),
  ("parseQuerySingle", testParseQuerySingle),
  ("parseQueryMultiple", testParseQueryMultiple),
  ("parseQueryNoValue", testParseQueryNoValue),
  ("parseQueryEmptyString", testParseQueryEmptyString),
  ("toHexSmall", testToHexSmall),
  ("toHexLarge", testToHexLarge),
  ("chunkEncodeSingle", chunkSingle),
  ("chunkEncodeMultiple", chunkMultiple),
  ("chunkEncodeEmpty", chunkEmpty)
  ]
