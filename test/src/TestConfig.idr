module TestConfig

import Flux.Server.Config
import System

%default covering

-- get/set round-trips

export
testStringRoundTrip : Bool
testStringRoundTrip = getString "key" (setString "key" "value" empty) == Just "value"

export
testIntRoundTrip : Bool
testIntRoundTrip = getInt "key" (setInt "key" 42 empty) == Just 42

export
testBoolRoundTrip : Bool
testBoolRoundTrip = getBool "key" (setBool "key" True empty) == Just True

export
testGetMissing : Bool
testGetMissing = getString "missing" empty == Nothing

export
testGetDefault : Bool
testGetDefault = getStringDef "missing" "fallback" empty == "fallback"

-- ConfigString fallback parsing (needed since env-sourced values are
-- always strings, but getInt/getBool used to only match ConfigInt/ConfigBool)

export
testGetIntFromString : Bool
testGetIntFromString = getInt "key" (setString "key" "123" empty) == Just 123

export
testGetIntFromStringInvalid : Bool
testGetIntFromStringInvalid = getInt "key" (setString "key" "not-a-number" empty) == Nothing

export
testGetBoolFromStringTrue : Bool
testGetBoolFromStringTrue =
  getBool "a" (setString "a" "true" empty) == Just True &&
  getBool "b" (setString "b" "1" empty) == Just True

export
testGetBoolFromStringFalse : Bool
testGetBoolFromStringFalse =
  getBool "a" (setString "a" "false" empty) == Just False &&
  getBool "b" (setString "b" "0" empty) == Just False

export
testGetBoolFromStringInvalid : Bool
testGetBoolFromStringInvalid = getBool "key" (setString "key" "maybe" empty) == Nothing

-- loadFromEnv, against real (temporarily set) environment variables

export
testLoadFromEnv : IO Bool
testLoadFromEnv = do
  _ <- setEnv "FLUXTEST_SERVER_HOST" "example.com" True
  _ <- setEnv "FLUXTEST_SERVER_PORT" "9090" True
  _ <- setEnv "IGNORED_VAR" "should not appear" True
  cfg <- loadFromEnv "FLUXTEST_"
  _ <- unsetEnv "FLUXTEST_SERVER_HOST"
  _ <- unsetEnv "FLUXTEST_SERVER_PORT"
  _ <- unsetEnv "IGNORED_VAR"
  pure $ getString "server.host" cfg == Just "example.com" &&
         getInt "server.port" cfg == Just 9090 &&
         getString "ignored.var" cfg == Nothing

export
testServerConfigFromEnv : IO Bool
testServerConfigFromEnv = do
  _ <- setEnv "FLUX_SERVER_PORT" "9999" True
  sc <- serverConfigFromEnv
  _ <- unsetEnv "FLUX_SERVER_PORT"
  pure (sc.port == 9999)

-- Run all config tests (mixing pure and IO-backed cases, unlike the other
-- suites, since env-var loading is inherently effectful)
export
runAllTests : IO (List (String, Bool))
runAllTests = do
  envResult <- testLoadFromEnv
  serverEnvResult <- testServerConfigFromEnv
  pure
    [ ("stringRoundTrip", testStringRoundTrip)
    , ("intRoundTrip", testIntRoundTrip)
    , ("boolRoundTrip", testBoolRoundTrip)
    , ("getMissing", testGetMissing)
    , ("getDefault", testGetDefault)
    , ("getIntFromString", testGetIntFromString)
    , ("getIntFromStringInvalid", testGetIntFromStringInvalid)
    , ("getBoolFromStringTrue", testGetBoolFromStringTrue)
    , ("getBoolFromStringFalse", testGetBoolFromStringFalse)
    , ("getBoolFromStringInvalid", testGetBoolFromStringInvalid)
    , ("loadFromEnv", envResult)
    , ("serverConfigFromEnv", serverEnvResult)
    ]
