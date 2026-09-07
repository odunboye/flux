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
  ("decodeNumber", testDecodeNumber)
  ]
