module TestJSON

import Flux.Data.JSON
import Data.SortedMap

%default total
%language ElabReflection

-- Test toJSON for Bool
export partial
testToJSONBool : Bool
testToJSONBool =
  toJSON True == JBool True

-- Test toJSON for String
export partial
testToJSONString : Bool
testToJSONString =
  toJSON "hello" == JString "hello"

-- Test toJSON for Number
export partial
testToJSONNumber : Bool
testToJSONNumber =
  toJSON (the Double 42.0) == JNumber 42.0

-- Test fromJSON for Bool
export partial
testFromJSONBool : Bool
testFromJSONBool =
  case fromJSON {a = Bool} (JBool True) of
    Just b => b == True
    Nothing => False

-- Test fromJSON failure
export partial
testFromJSONFailure : Bool
testFromJSONFailure =
  case fromJSON {a = Bool} (JNumber 1.0) of
    Nothing => True
    Just _ => False

-- Test encode null
export partial
testEncodeNull : Bool
testEncodeNull =
  encode JNull == "null"

-- Test encode bool
export partial
testEncodeBool : Bool
testEncodeBool =
  encode (JBool True) == "true"

-- Test encode string
export partial
testEncodeString : Bool
testEncodeString =
  encode (JString "hello") == "\"hello\""

-- Test encode number
export partial
testEncodeNumber : Bool
testEncodeNumber =
  encode (JNumber 42.0) == "42.0"

-- Test Eq JSON
export partial
testEqJSON : Bool
testEqJSON =
  (JBool True == JBool True) &&
  (JBool True /= JBool False)

-- Test decode JSON string
export partial
testDecode : Bool
testDecode =
  case decode {a = Bool} "true" of
    Just True => True
    _ => False

-- Test decode JSON number
export partial
testDecodeNumber : Bool
testDecodeNumber =
  case decode {a = Double} "42.5" of
    Just 42.5 => True
    _ => False

-- Regression coverage for a set of pre-existing parser bugs found and
-- fixed while implementing readBody (see Flux.Data.JSON's docs on
-- parseValue/parseStringLit): none of the above tests ever decoded an
-- object, an array, or a string value (only "true"/"42.5" scalars), so
-- none of them caught that multi-key objects, multi-element arrays, and
-- string values (reversed on decode!) were all broken.

export partial
testDecodeStringValue : Bool
testDecodeStringValue =
  case json "\"hello\"" of
    Right (JString "hello") => True
    _                       => False

export partial
testDecodeObjectMultiKey : Bool
testDecodeObjectMultiKey =
  case json "{\"name\":\"Carol\",\"email\":\"carol@example.com\"}" of
    Right (JObject kvs) =>
      Data.SortedMap.lookup "name" kvs  == Just (JString "Carol") &&
      Data.SortedMap.lookup "email" kvs == Just (JString "carol@example.com")
    _ => False

export partial
testDecodeArrayMultiElement : Bool
testDecodeArrayMultiElement =
  case json "[1,2,3]" of
    Right (JArray [JNumber 1.0, JNumber 2.0, JNumber 3.0]) => True
    _                                                      => False

export partial
testDecodeNestedObjectAndArray : Bool
testDecodeNestedObjectAndArray =
  case json "{\"a\":[1,2],\"b\":{\"c\":3}}" of
    Right (JObject kvs) =>
      Data.SortedMap.lookup "a" kvs == Just (JArray [JNumber 1.0, JNumber 2.0]) &&
      Data.SortedMap.lookup "b" kvs == Just (JObject (fromList [("c", JNumber 3.0)]))
    _ => False

export partial
testDecodeWhitespaceTolerant : Bool
testDecodeWhitespaceTolerant =
  case json "  {  \"a\" : 1 , \"b\" : 2 }  " of
    Right (JObject kvs) =>
      Data.SortedMap.lookup "a" kvs == Just (JNumber 1.0) &&
      Data.SortedMap.lookup "b" kvs == Just (JNumber 2.0)
    _ => False

-- Run all JSON tests
export partial
runAllTests : List (String, Bool)
runAllTests = [
  ("toJSONBool", testToJSONBool),
  ("toJSONString", testToJSONString),
  ("toJSONNumber", testToJSONNumber),
  ("fromJSONBool", testFromJSONBool),
  ("fromJSONFailure", testFromJSONFailure),
  ("encodeNull", testEncodeNull),
  ("encodeBool", testEncodeBool),
  ("encodeString", testEncodeString),
  ("encodeNumber", testEncodeNumber),
  ("eqJSON", testEqJSON),
  ("decode", testDecode),
  ("decodeNumber", testDecodeNumber),
  ("decodeStringValue", testDecodeStringValue),
  ("decodeObjectMultiKey", testDecodeObjectMultiKey),
  ("decodeArrayMultiElement", testDecodeArrayMultiElement),
  ("decodeNestedObjectAndArray", testDecodeNestedObjectAndArray),
  ("decodeWhitespaceTolerant", testDecodeWhitespaceTolerant)
  ]
