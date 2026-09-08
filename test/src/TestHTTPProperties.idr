||| Property-based tests for Flux.Core.HTTP's wire parser (method,
||| version, start line, headers, query string, and the full request
||| parser), using idris2-hedgehog. Complements TestHTTP.idr's example-
||| based tests rather than replacing them: hand-picked examples are
||| good at pinning down specific known cases, but this project's own
||| JSON parser had three real, compounding bugs that no hand-picked
||| example ever caught (see Flux.Middleware.JSON's doc comment) - only
||| decoding something with more than one array element/object key ever
||| would have. This suite exists so the same class of bug in the HTTP
||| wire parser (which is exactly the same shape of hand-rolled,
||| stateful parsing code) doesn't go undetected the same way.
|||
||| A genuine example of this working as intended, found while writing
||| it (not hypothetical): a naive "headers round-trip exactly" property
||| failed within 45 generated cases on a header value that was pure
||| whitespace (" ") - parsed back as "". On inspection this is Flux
||| behaving *correctly* (RFC 7230 header values have their surrounding
||| whitespace stripped, so a value of solely whitespace legitimately
||| becomes empty) - the property's own expectation was too naive.
||| `propHeadersRoundTrip` below expects `trim v`, not `v`, for exactly
||| this reason - a precise, correct specification the naive version
||| didn't have.
module TestHTTPProperties

import Flux.Core.HTTP
import Data.SortedMap
import Data.String
import Data.List
import Data.Vect
import Data.IORef
import Hedgehog

%default covering

--------------------------------------------------------------------------------
-- Generators
--------------------------------------------------------------------------------

lowerAlpha : Vect 26 Char
lowerAlpha = fromList (unpack "abcdefghijklmnopqrstuvwxyz")

alphaNum : Vect 62 Char
alphaNum = fromList (unpack "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")

headerValueChars : Vect 65 Char
headerValueChars = fromList (unpack "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 -.")

mixedCaseAlpha : Vect 52 Char
mixedCaseAlpha = fromList (unpack "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")

allMethods : Vect 7 Method
allMethods = [GET, POST, HEAD, PUT, DELETE, PATCH, OPTIONS]

genMethod : Gen Method
genMethod = element allMethods

-- Version has no Show in Flux.Core.HTTP - the exact wire strings `version`
-- itself accepts, kept here so the property is checking `version` against
-- real input, not against a second copy of version's own parsing logic.
showVersion : Version -> String
showVersion V10 = "HTTP/1.0"
showVersion V11 = "HTTP/1.1"
showVersion V20 = "HTTP/2.0"

-- forAll requires Show (for diff-printing on a failing case) - Version
-- has none in Flux.Core.HTTP itself, so this is a local orphan instance
-- for test purposes only.
Show Version where
  show = showVersion

allVersions : Vect 3 Version
allVersions = [V10, V11, V20]

genVersion : Gen Version
genVersion = element allVersions

genPathSegment : Gen String
genPathSegment = string (linear 1 10) (element alphaNum)

genPath : Gen String
genPath = do
  segs <- list (linear 1 4) genPathSegment
  pure ("/" ++ joinBy "/" segs)

genHeaderName : Gen String
genHeaderName = string (linear 1 15) (element lowerAlpha)

-- Same charset as genHeaderName but mixed-case, for propHeadersNamesAreCaseInsensitive.
genMixedCaseHeaderName : Gen String
genMixedCaseHeaderName = string (linear 1 15) (element mixedCaseAlpha)

genHeaderValue : Gen String
genHeaderValue = string (linear 0 30) (element headerValueChars)

genHeaderPair : Gen (String, String)
genHeaderPair = [| (,) genHeaderName genHeaderValue |]

genQueryKey : Gen String
genQueryKey = string (linear 1 8) (element alphaNum)

genQueryValue : Gen String
genQueryValue = string (linear 0 8) (element alphaNum)

genQueryPair : Gen (String, String)
genQueryPair = [| (,) genQueryKey genQueryValue |]

genBody : Gen String
genBody = string (linear 0 50) (element alphaNum)

-- Later entries win on a duplicate key, matching headers/parseQuery's
-- own left-to-right `insert` semantics - keep only the last occurrence
-- per key so a round-trip check against a Bool "did every unique pair
-- survive" property has one unambiguous expected value per key.
lastByKey : List (String, String) -> List (String, String)
lastByKey = nubBy (\a, b => fst a == fst b) . reverse

--------------------------------------------------------------------------------
-- method / version
--------------------------------------------------------------------------------

export
propMethodRoundTrip : Property
propMethodRoundTrip = property $ do
  m <- forAll genMethod
  method (show m) === Right m

export
propVersionRoundTrip : Property
propVersionRoundTrip = property $ do
  v <- forAll genVersion
  version (showVersion v) === Right v

--------------------------------------------------------------------------------
-- startLine
--------------------------------------------------------------------------------

export
propStartLineRoundTrip : Property
propStartLineRoundTrip = property $ do
  m    <- forAll genMethod
  path <- forAll genPath
  v    <- forAll genVersion
  let line = fromString (show m ++ " " ++ path ++ " " ++ showVersion v)
  startLine line === Right (m, path, v)

--------------------------------------------------------------------------------
-- headers
--------------------------------------------------------------------------------

headerLine : (String, String) -> ByteString
headerLine (k, v) = fromString (k ++ ": " ++ v)

export
propHeadersRoundTrip : Property
propHeadersRoundTrip = property $ do
  pairs <- forAll (list (linear 0 10) genHeaderPair)
  let ls = map headerLine pairs
  case headers empty ls of
    Left e   => footnote "parse failed: \{show e}" *> failure
    Right hs => for_ (lastByKey pairs) $ \(k, v) =>
      -- See the module doc comment - values are trimmed of surrounding
      -- OWS on parse (correct per RFC 7230), so the round-trip is
      -- against `trim v`, not `v` itself.
      Data.SortedMap.lookup k hs === Just (trim v)

export
propHeadersNamesAreCaseInsensitive : Property
propHeadersNamesAreCaseInsensitive = property $ do
  name <- forAll genMixedCaseHeaderName
  val  <- forAll genHeaderValue
  case headers empty [headerLine (name, val)] of
    Left e   => footnote "parse failed: \{show e}" *> failure
    Right hs => Data.SortedMap.lookup (toLower name) hs === Just (trim val)

--------------------------------------------------------------------------------
-- splitQuery / parseQuery
--------------------------------------------------------------------------------

export
propSplitQueryRoundTrip : Property
propSplitQueryRoundTrip = property $ do
  path <- forAll genPath
  qs   <- forAll (string (linear 0 20) (element alphaNum))
  let combined = if qs == "" then path else path ++ "?" ++ qs
  splitQuery combined === (path, qs)

export
propParseQueryRoundTrip : Property
propParseQueryRoundTrip = property $ do
  pairs <- forAll (list (linear 0 8) genQueryPair)
  let qs     := joinBy "&" (map (\(k, v) => k ++ "=" ++ v) pairs)
      parsed := parseQuery qs
  for_ (lastByKey pairs) $ \(k, v) => Data.SortedMap.lookup k parsed === Just v

--------------------------------------------------------------------------------
-- request / assemble (the full wire parser, over the real async runtime)
--------------------------------------------------------------------------------

record ParsedRequest where
  constructor MkParsedRequest
  method  : Method
  uri     : String
  query   : SortedMap String String
  version : Version
  headers : Headers
  length  : Nat
  type    : Maybe String
  bodyStr : String

-- Runs `request` for real over a single in-memory ByteString standing in
-- for a connection's byte stream, then also drains the parsed request's
-- own body (see HTTPBody's docs - this is normally the driver's job,
-- done here directly since there is no driver in this test) so the
-- property below can check its content too, not just the headers.
covering
runRequestParse : (maxBodySize : Nat) -> ByteString -> IO (Maybe ParsedRequest)
runRequestParse maxBodySize rawBytes = do
  resultRef <- newIORef Nothing
  runProg $
    handleErrors
      (\case
        Here e         => liftIO (putStrLn "runRequestParse: unexpected Errno: \{e}")
        There (Here e) => liftIO (putStrLn "runRequestParse: unexpected HTTPErr: \{e}"))
      (Prelude.do
        mreq <- request maxBodySize (emit rawBytes)
        case mreq of
          Nothing  => pure ()
          Just req => do
            (bodyChunks, _) <- foldPair (:<) [<] req.body
            liftIO $ writeIORef resultRef $ Just $
              MkParsedRequest req.method req.uri req.query req.version
                req.headers req.length req.type
                (Data.ByteString.toString (fastConcat (bodyChunks <>> []))))
  readIORef resultRef

-- Builds a syntactically valid raw HTTP/1.x request off the generated
-- pieces. Adds a correct Content-Length for the generated body *unless*
-- the caller already supplied one of their own (needed by
-- `randomOversizedCaseOk` below, to send a deliberately-wrong one) -
-- appending a second, correct one regardless would just silently
-- override the caller's, since headers's later-entry-wins semantics
-- means whichever one is LAST in the raw text always decides.
buildRawRequest :
     Method -> String -> List (String,String) -> Version -> List (String,String) -> String
  -> ByteString
buildRawRequest m path qPairs v hdrPairs body =
  let qs       := joinBy "&" (map (\(k,val) => k ++ "=" ++ val) qPairs)
      target   := if qs == "" then path else path ++ "?" ++ qs
      startL   := show m ++ " " ++ target ++ " " ++ showVersion v
      callerCL := any (\(k,_) => toLower k == "content-length") hdrPairs
      allHdrs  := if callerCL then hdrPairs else hdrPairs ++ [("content-length", show (length body))]
      hdrLines := map headerText allHdrs
      full     := startL ++ "\r\n" ++ joinBy "\r\n" hdrLines ++ "\r\n\r\n" ++ body
   in fromString full
  where
    headerText : (String, String) -> String
    headerText (k, val) = k ++ ": " ++ val

-- Not a `Property`/`check`: `property`'s do-block runs in a purely
-- generator-based monad (`EitherT Failure (WriterT Journal Gen)`) with
-- no `HasIO`/`MonadIO` instance at all - confirmed directly (the build
-- fails immediately trying to `liftIO` inside one), matching this
-- library's own documented limitation ("Gen is not a monad transformer
-- right now, therefore it cannot be combined with additional monadic
-- effects"). `request` genuinely needs the real async runtime to run at
-- all, so it can't be tested via `property`/`forAll`/`check`. Instead:
-- `Hedgehog.Gen.sample : HasIO io => Gen a -> io a` draws one random
-- value in plain IO, used here in an ordinary loop - the same
-- randomized-input value as the properties above, minus hedgehog's
-- automatic shrinking of a failing case (there's nothing to shrink
-- against without the `property` framework).
randomRequestCaseOk : IO Bool
randomRequestCaseOk = do
  m        <- sample genMethod
  path     <- sample genPath
  qPairs   <- sample (list (linear 0 3) genQueryPair)
  v        <- sample genVersion
  hdrPairs <- sample (list (linear 0 3) genHeaderPair)
  body     <- sample genBody
  let raw = buildRawRequest m path qPairs v hdrPairs body
  mresult <- runRequestParse 1_000_000 raw
  case mresult of
    Nothing => do
      putStrLn "requestRoundTrip: failed to parse \{show raw}"
      pure False
    Just pr =>
      pure $ pr.method == m
          && pr.uri    == path
          && pr.version == v
          && pr.length == length body
          && pr.bodyStr == body
          && all (\(k,val) => Data.SortedMap.lookup k pr.query == Just val) (lastByKey qPairs)
          && all (\(k,val) => Data.SortedMap.lookup k pr.headers == Just (trim val)) (lastByKey hdrPairs)

export covering
testRequestRoundTrip : IO Bool
testRequestRoundTrip = all id <$> traverse (const randomRequestCaseOk) [the Nat 1 .. 50]

-- A declared Content-Length over maxBodySize is rejected (ContentSizeExceeded),
-- not silently accepted or truncated.
randomOversizedCaseOk : IO Bool
randomOversizedCaseOk = do
  m    <- sample genMethod
  path <- sample genPath
  v    <- sample genVersion
  let raw = buildRawRequest m path [] v [("content-length", "999999999")] ""
  mresult <- runRequestParse 100 raw
  pure $ case mresult of
    Nothing => True
    Just _  => False

export covering
testRequestRejectsOversizedContentLength : IO Bool
testRequestRejectsOversizedContentLength = all id <$> traverse (const randomOversizedCaseOk) [the Nat 1 .. 20]

--------------------------------------------------------------------------------
-- Run all property tests
--------------------------------------------------------------------------------

export
runAllTests : IO (List (String, Bool))
runAllTests = do
  methodOk        <- check propMethodRoundTrip
  versionOk       <- check propVersionRoundTrip
  startLineOk     <- check propStartLineRoundTrip
  headersOk       <- check propHeadersRoundTrip
  headersCaseOk   <- check propHeadersNamesAreCaseInsensitive
  splitQueryOk    <- check propSplitQueryRoundTrip
  parseQueryOk    <- check propParseQueryRoundTrip
  requestOk       <- testRequestRoundTrip
  oversizedOk     <- testRequestRejectsOversizedContentLength
  pure
    [ ("methodRoundTrip", methodOk)
    , ("versionRoundTrip", versionOk)
    , ("startLineRoundTrip", startLineOk)
    , ("headersRoundTrip", headersOk)
    , ("headersNamesAreCaseInsensitive", headersCaseOk)
    , ("splitQueryRoundTrip", splitQueryOk)
    , ("parseQueryRoundTrip", parseQueryOk)
    , ("requestRoundTrip", requestOk)
    , ("requestRejectsOversizedContentLength", oversizedOk)
    ]
