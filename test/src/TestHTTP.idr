module TestHTTP

import Flux.Core.HTTP
import Data.SortedMap
import Data.IORef
import Data.Vect
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

-- Method names are case-sensitive per RFC 9110, unlike header names -
-- "get" is a different (unknown) token from "GET".
export
testMethodLowercaseRejected : Bool
testMethodLowercaseRejected = method "get" == Left InvalidRequest

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

export
testHeadersRejectsDuplicateContentLength : Bool
testHeadersRejectsDuplicateContentLength =
  case headers empty [fromString "Content-Length: 5", fromString "Content-Length: 10"] of
    Left InvalidRequest => True
    _                   => False

export
testHeadersRejectsTransferEncoding : Bool
testHeadersRejectsTransferEncoding =
  case headers empty [fromString "Transfer-Encoding: chunked"] of
    Left InvalidRequest => True
    _                   => False

-- RFC 9112 §5.1: whitespace between a header name and its colon must be
-- rejected, not silently accepted - a lenient parser storing "content-
-- length " (trailing space) under a different map key than "content-
-- length" would let the real Content-Length header go unrecognized
-- entirely (missed by both this exact duplicate check and
-- contentLength's own lookup), exactly the kind of parser disagreement
-- that enables request smuggling behind a stricter proxy.
export
testHeadersRejectsSpaceBeforeColon : Bool
testHeadersRejectsSpaceBeforeColon =
  case headers empty [fromString "Content-Length : 5"] of
    Left InvalidRequest => True
    _                   => False

export
testHeadersRejectsTabBeforeColon : Bool
testHeadersRejectsTabBeforeColon =
  case headers empty [fromString "Content-Length\t: 5"] of
    Left InvalidRequest => True
    _                   => False

export
testHeadersRejectsSpaceBeforeColonTransferEncoding : Bool
testHeadersRejectsSpaceBeforeColonTransferEncoding =
  case headers empty [fromString "Transfer-Encoding : chunked"] of
    Left InvalidRequest => True
    _                   => False

-- A duplicate Host header is rejected outright, same shape as the
-- existing duplicate-Content-Length check - a real cache-poisoning/
-- routing-confusion vector if silently accepted (whichever Host a
-- downstream proxy trusts may disagree with whichever one Flux uses).
export
testHeadersRejectsDuplicateHost : Bool
testHeadersRejectsDuplicateHost =
  case headers empty [fromString "Host: a.example", fromString "Host: b.example"] of
    Left InvalidRequest => True
    _                   => False

-- Obsolete line-folding: a continuation line (starting with whitespace,
-- no colon of its own) is not a valid standalone header line - it must
-- hit the same InvalidRequest catch-all as any other colon-less line,
-- not be silently merged into the previous header's value (which this
-- parser was traced as never having implemented support for at all).
export
testHeadersRejectsObsoleteLineFolding : Bool
testHeadersRejectsObsoleteLineFolding =
  case headers empty [fromString "X-Custom: first", fromString "  continued"] of
    Left InvalidRequest => True
    _                   => False

-- contentLength / contentType

export
testContentLength : Bool
testContentLength = contentLength (fromList [("content-length", "42")]) == Right 42

export
testContentLengthMissing : Bool
testContentLengthMissing = contentLength empty == Right 0

export
testContentLengthMalformed : Bool
testContentLengthMalformed =
  case contentLength (fromList [("content-length", "12abc")]) of
    Left InvalidRequest => True
    _                   => False

export
testContentLengthEmpty : Bool
testContentLengthEmpty =
  case contentLength (fromList [("content-length", "")]) of
    Left InvalidRequest => True
    _                   => False

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

export
testParseQueryPercentDecoded : Bool
testParseQueryPercentDecoded = lookup "q" (parseQuery "q=hello%20world") == Just "hello world"

export
testParseQueryKeyPercentDecoded : Bool
testParseQueryKeyPercentDecoded = lookup "a b" (parseQuery "a%20b=1") == Just "1"

-- percentDecode

export
testPercentDecodeBasic : Bool
testPercentDecodeBasic = percentDecode "hello%20world" == "hello world"

export
testPercentDecodeNoEscapes : Bool
testPercentDecodeNoEscapes = percentDecode "plain" == "plain"

export
testPercentDecodeMalformedTrailing : Bool
testPercentDecodeMalformedTrailing = percentDecode "100%" == "100%"

export
testPercentDecodeMalformedNonHex : Bool
testPercentDecodeMalformedNonHex = percentDecode "100%zz" == "100%zz"

export
testPercentDecodeLowercaseHex : Bool
testPercentDecodeLowercaseHex = percentDecode "%2f" == "/"

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

-- A mid-stream empty ByteString emission must not be framed - chunkFrame
-- on an empty ByteString is byte-identical to chunkTerminator, so
-- framing one would signal end-of-body early and leave anything after
-- it as unframed trailing bytes.
export
testChunkEncodeSkipsEmptyEmission : IO Bool
testChunkEncodeSkipsEmptyEmission = do
  out <- runStream (chunkEncode (emit (fromString "hello") >> emit (fromString "") >> emit (fromString "world")))
  pure (toString out == "5\r\nhello\r\n5\r\nworld\r\n0\r\n\r\n")

export
testParseIPv4Loopback : Bool
testParseIPv4Loopback = parseIPv4 "127.0.0.1" == Just [127,0,0,1]

export
testParseIPv4AllInterfaces : Bool
testParseIPv4AllInterfaces = parseIPv4 "0.0.0.0" == Just [0,0,0,0]

export
testParseIPv4MaxOctet : Bool
testParseIPv4MaxOctet = parseIPv4 "255.255.255.255" == Just [255,255,255,255]

export
testParseIPv4OutOfRangeOctet : Bool
testParseIPv4OutOfRangeOctet = parseIPv4 "256.0.0.1" == Nothing

export
testParseIPv4WrongSegmentCount : Bool
testParseIPv4WrongSegmentCount =
  parseIPv4 "127.0.1" == Nothing && parseIPv4 "127.0.0.0.1" == Nothing

export
testParseIPv4NonNumeric : Bool
testParseIPv4NonNumeric = parseIPv4 "localhost" == Nothing && parseIPv4 "127.0.0.x" == Nothing

--------------------------------------------------------------------------------
-- request: full wire-level parsing (Host requirement, CR/LF/NUL safety)
--------------------------------------------------------------------------------

-- Runs `request` for real over a single in-memory ByteString, draining
-- the parsed request's body (mirroring TestHTTPProperties's
-- runRequestParse) so nothing is left unconsumed. `Nothing` covers both
-- "no request at all" and "rejected while parsing" - same convention as
-- TestHTTPProperties's oversized/truncated-body tests, which is all
-- these tests need: whether parsing succeeded or was rejected, not why.
runRequest : (maxBodySize : Nat) -> String -> IO (Maybe Request)
runRequest maxBodySize raw = do
  resultRef <- newIORef Nothing
  runProg $
    handleErrors
      (\case
        Here e         => liftIO (putStrLn "runRequest: unexpected Errno: \{e}")
        There (Here e) => pure ())
      (Prelude.do
        mreq <- request maxBodySize (emit (fromString raw))
        case mreq of
          Nothing  => pure ()
          Just req => do
            _ <- foldPair (:<) [<] req.body
            liftIO $ writeIORef resultRef (Just req))
  readIORef resultRef

-- RFC 9112 §3.2: an HTTP/1.1 request with no Host header is rejected.
export
testRequestRejectsMissingHostOnV11 : IO Bool
testRequestRejectsMissingHostOnV11 = do
  mreq <- runRequest 1000 "GET / HTTP/1.1\r\n\r\n"
  pure $ case mreq of
    Nothing => True
    Just _  => False

-- HTTP/1.0 predates Host - a request with none still parses.
export
testRequestAllowsMissingHostOnV10 : IO Bool
testRequestAllowsMissingHostOnV10 = do
  mreq <- runRequest 1000 "GET / HTTP/1.0\r\n\r\n"
  pure $ case mreq of
    Just req => req.version == V10
    Nothing  => False

-- A duplicate Host header is rejected at the full request-parse level
-- too, not just via the header table unit test above.
export
testRequestRejectsDuplicateHost : IO Bool
testRequestRejectsDuplicateHost = do
  mreq <- runRequest 1000 "GET / HTTP/1.1\r\nHost: a.example\r\nHost: b.example\r\n\r\n"
  pure $ case mreq of
    Nothing => True
    Just _  => False

-- Method names are case-sensitive (RFC 9110): a lowercase "get" is not
-- the same token as "GET" and must be rejected, unlike header names.
export
testRequestRejectsLowercaseMethod : IO Bool
testRequestRejectsLowercaseMethod = do
  mreq <- runRequest 1000 "get / HTTP/1.1\r\nHost: a.example\r\n\r\n"
  pure $ case mreq of
    Nothing => True
    Just _  => False

-- A non-origin-form request-target (absolute-form, here) is accepted by
-- startLine as a literal path string rather than causing anything worse
-- than a request that simply won't match any route later on - `request`
-- itself has no route-matching, so this only confirms parsing succeeds
-- with the target preserved verbatim, not turned into something unsafe.
export
testRequestAcceptsAbsoluteFormTargetAsLiteralPath : IO Bool
testRequestAcceptsAbsoluteFormTargetAsLiteralPath = do
  mreq <- runRequest 1000 "GET http://a.example/x HTTP/1.1\r\nHost: a.example\r\n\r\n"
  pure $ case mreq of
    Just req => req.uri == "http://a.example/x"
    Nothing  => False

-- CR/LF bytes can't end up embedded *inside* a single parsed header
-- value: the wire format itself already uses "\r\n" as the line
-- delimiter (see `lines`, which splits on it before any header value is
-- extracted), so what might look like an attempt to smuggle a second
-- header line through one value just parses as two genuinely separate,
-- correctly-split headers instead - confirmed here by checking both
-- values came through intact and independent, rather than one value
-- containing the other's text.
export
testRequestCRLFCannotSmuggleAHeaderValue : IO Bool
testRequestCRLFCannotSmuggleAHeaderValue = do
  mreq <- runRequest 1000 "GET / HTTP/1.1\r\nHost: a.example\r\nX-Evil: a\r\nInjected: line\r\n\r\n"
  pure $ case mreq of
    Just req => lookup "x-evil" req.headers == Just "a" &&
                lookup "injected" req.headers == Just "line"
    Nothing  => False

-- Run all HTTP wire-parser tests (mixing pure and IO-backed cases, since
-- chunk-encoding needs the real async runtime to exercise)
export
runAllTests : IO (List (String, Bool))
runAllTests = do
  chunkSingle     <- testChunkEncodeSingle
  chunkMultiple   <- testChunkEncodeMultiple
  chunkEmpty      <- testChunkEncodeEmpty
  chunkSkipsEmpty <- testChunkEncodeSkipsEmptyEmission
  reqRejectsMissingHostV11 <- testRequestRejectsMissingHostOnV11
  reqAllowsMissingHostV10  <- testRequestAllowsMissingHostOnV10
  reqRejectsDuplicateHost  <- testRequestRejectsDuplicateHost
  reqRejectsLowercaseMethod <- testRequestRejectsLowercaseMethod
  reqAcceptsAbsoluteForm   <- testRequestAcceptsAbsoluteFormTargetAsLiteralPath
  reqCRLFCannotSmuggle     <- testRequestCRLFCannotSmuggleAHeaderValue
  pure $
   [ ("methodGet", testMethodGet),
  ("methodAllVariants", testMethodAllVariants),
  ("methodUnknown", testMethodUnknown),
  ("methodLowercaseRejected", testMethodLowercaseRejected),
  ("version11", testVersion11),
  ("versionUnknown", testVersionUnknown),
  ("startLineValid", testStartLineValid),
  ("startLineWrongArity", testStartLineWrongArity),
  ("startLineBadMethod", testStartLineBadMethod),
  ("headersParse", testHeadersParse),
  ("headersLowercasesNames", testHeadersLowercasesNames),
  ("headersMalformed", testHeadersMalformed),
  ("headersEmpty", testHeadersEmpty),
  ("headersRejectsDuplicateContentLength", testHeadersRejectsDuplicateContentLength),
  ("headersRejectsTransferEncoding", testHeadersRejectsTransferEncoding),
  ("headersRejectsSpaceBeforeColon", testHeadersRejectsSpaceBeforeColon),
  ("headersRejectsTabBeforeColon", testHeadersRejectsTabBeforeColon),
  ("headersRejectsSpaceBeforeColonTransferEncoding", testHeadersRejectsSpaceBeforeColonTransferEncoding),
  ("headersRejectsDuplicateHost", testHeadersRejectsDuplicateHost),
  ("headersRejectsObsoleteLineFolding", testHeadersRejectsObsoleteLineFolding),
  ("contentLength", testContentLength),
  ("contentLengthMissing", testContentLengthMissing),
  ("contentLengthMalformed", testContentLengthMalformed),
  ("contentLengthEmpty", testContentLengthEmpty),
  ("contentType", testContentType),
  ("splitQueryPresent", testSplitQueryPresent),
  ("splitQueryAbsent", testSplitQueryAbsent),
  ("splitQueryEmpty", testSplitQueryEmpty),
  ("parseQuerySingle", testParseQuerySingle),
  ("parseQueryMultiple", testParseQueryMultiple),
  ("parseQueryNoValue", testParseQueryNoValue),
  ("parseQueryEmptyString", testParseQueryEmptyString),
  ("parseQueryPercentDecoded", testParseQueryPercentDecoded),
  ("parseQueryKeyPercentDecoded", testParseQueryKeyPercentDecoded),
  ("percentDecodeBasic", testPercentDecodeBasic),
  ("percentDecodeNoEscapes", testPercentDecodeNoEscapes),
  ("percentDecodeMalformedTrailing", testPercentDecodeMalformedTrailing),
  ("percentDecodeMalformedNonHex", testPercentDecodeMalformedNonHex),
  ("percentDecodeLowercaseHex", testPercentDecodeLowercaseHex),
  ("toHexSmall", testToHexSmall),
  ("toHexLarge", testToHexLarge),
  ("chunkEncodeSingle", chunkSingle),
  ("chunkEncodeMultiple", chunkMultiple),
  ("chunkEncodeEmpty", chunkEmpty),
  ("chunkEncodeSkipsEmptyEmission", chunkSkipsEmpty),
  ("parseIPv4Loopback", testParseIPv4Loopback),
  ("parseIPv4AllInterfaces", testParseIPv4AllInterfaces),
  ("parseIPv4MaxOctet", testParseIPv4MaxOctet),
  ("parseIPv4OutOfRangeOctet", testParseIPv4OutOfRangeOctet),
  ("parseIPv4WrongSegmentCount", testParseIPv4WrongSegmentCount),
  ("parseIPv4NonNumeric", testParseIPv4NonNumeric),
  ("requestRejectsMissingHostOnV11", reqRejectsMissingHostV11),
  ("requestAllowsMissingHostOnV10", reqAllowsMissingHostV10),
  ("requestRejectsDuplicateHost", reqRejectsDuplicateHost),
  ("requestRejectsLowercaseMethod", reqRejectsLowercaseMethod),
  ("requestAcceptsAbsoluteFormTargetAsLiteralPath", reqAcceptsAbsoluteForm),
  ("requestCRLFCannotSmuggleAHeaderValue", reqCRLFCannotSmuggle)
  ]
