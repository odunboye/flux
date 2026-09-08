||| Tests for Flux.Middleware.JSON - the Flux-specific glue between
||| json-simple and Context/Request/ErrorRenderer. JSON encode/decode
||| correctness itself is json-simple's own responsibility (and its own
||| test suite's job), not re-tested here - see that module's doc
||| comment for why Flux used to have its own hand-rolled parser (with
||| real bugs) and no longer does.
module TestJSON

import Flux.Core.HTTP
import Flux.Core.Middleware
import Flux.Middleware.JSON
import JSON.Simple.Derive
import Data.SortedMap

%default total
%language ElabReflection

record Widget where
  constructor MkWidget
  name  : String
  count : Nat

%runElab derive "Widget" [Show,Eq,ToJSON,FromJSON]

dummyRequest : Request
dummyRequest = R GET "/" empty V11 empty 0 Nothing (pure (pure ()))

dummyRequestWithType : Maybe String -> Request
dummyRequestWithType ty = R GET "/" empty V11 empty 0 ty (pure (pure ()))

-- sendJSON

export
testSendJSONSetsContentType : Bool
testSendJSONSetsContentType =
  let ctx = sendJSON (MkWidget "cog" 3) (emptyContext dummyRequest)
   in Data.SortedMap.lookup "Content-Type" ctx.respHeaders == Just "application/json"

export
testSendJSONEncodesBody : Bool
testSendJSONEncodesBody =
  case sendJSON (MkWidget "cog" 3) (emptyContext dummyRequest) of
    ctx => case ctx.respBody of
      Buffered bs => decodeEither {a = Widget} (toString bs) == Right (MkWidget "cog" 3)
      Streamed _ _ => False

-- sendJSONError / jsonErrorRenderer

export
testSendJSONErrorSetsStatus : Bool
testSendJSONErrorSetsStatus =
  let ctx = sendJSONError 404 "not found" (emptyContext dummyRequest)
   in ctx.statusCode == 404

export
testSendJSONErrorBodyShapeIsErrorObject : Bool
testSendJSONErrorBodyShapeIsErrorObject =
  case sendJSONError 400 "bad request" (emptyContext dummyRequest) of
    ctx => case ctx.respBody of
      Buffered bs => toString bs == "{\"error\":\"bad request\"}"
      Streamed _ _ => False

export
testJsonErrorRendererMatchesSendJSONError : Bool
testJsonErrorRendererMatchesSendJSONError =
  let ctx = jsonErrorRenderer (MkAppError 418 "teapot") (emptyContext dummyRequest)
   in ctx.statusCode == 418 &&
      (case ctx.respBody of
        Buffered bs  => toString bs == "{\"error\":\"teapot\"}"
        Streamed _ _ => False)

-- isJSON

export
testIsJSONTrueForApplicationJSON : Bool
testIsJSONTrueForApplicationJSON = isJSON (dummyRequestWithType (Just "application/json"))

export
testIsJSONTrueWithCharset : Bool
testIsJSONTrueWithCharset = isJSON (dummyRequestWithType (Just "application/json; charset=utf-8"))

export
testIsJSONFalseForOtherType : Bool
testIsJSONFalseForOtherType = not (isJSON (dummyRequestWithType (Just "text/plain")))

export
testIsJSONFalseForNoType : Bool
testIsJSONFalseForNoType = not (isJSON (dummyRequestWithType Nothing))

-- jsonResponse / jsonError (standalone, outside Context)

export
testJsonResponseBody : Bool
testJsonResponseBody =
  Data.ByteString.isInfixOf (fromString "{\"name\":\"cog\",\"count\":3}") (jsonResponse (MkWidget "cog" 3))

export
testJsonResponseSetsContentType : Bool
testJsonResponseSetsContentType =
  Data.ByteString.isInfixOf (fromString "Content-Type: application/json") (jsonResponse (MkWidget "cog" 3))

export
testJsonErrorStandaloneBody : Bool
testJsonErrorStandaloneBody =
  Data.ByteString.isInfixOf (fromString "{\"error\":\"oops\"}") (jsonError 500 "oops")

-- Run all JSON tests
export
runAllTests : List (String, Bool)
runAllTests =
  [ ("sendJSONSetsContentType", testSendJSONSetsContentType)
  , ("sendJSONEncodesBody", testSendJSONEncodesBody)
  , ("sendJSONErrorSetsStatus", testSendJSONErrorSetsStatus)
  , ("sendJSONErrorBodyShapeIsErrorObject", testSendJSONErrorBodyShapeIsErrorObject)
  , ("jsonErrorRendererMatchesSendJSONError", testJsonErrorRendererMatchesSendJSONError)
  , ("isJSONTrueForApplicationJSON", testIsJSONTrueForApplicationJSON)
  , ("isJSONTrueWithCharset", testIsJSONTrueWithCharset)
  , ("isJSONFalseForOtherType", testIsJSONFalseForOtherType)
  , ("isJSONFalseForNoType", testIsJSONFalseForNoType)
  , ("jsonResponseBody", testJsonResponseBody)
  , ("jsonResponseSetsContentType", testJsonResponseSetsContentType)
  , ("jsonErrorStandaloneBody", testJsonErrorStandaloneBody)
  ]
