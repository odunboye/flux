module TestHTTP

import Flux.Core.HTTP
import Data.SortedMap

%default total

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

-- Run all HTTP wire-parser tests
export
runAllTests : List (String, Bool)
runAllTests = [
  ("methodGet", testMethodGet),
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
  ("parseQueryEmptyString", testParseQueryEmptyString)
  ]
