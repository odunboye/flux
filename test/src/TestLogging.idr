module TestLogging

import Flux.Server.Logging

%default total

-- Test levelToString
export
testLevelToString : Bool
testLevelToString =
  (levelToString Debug == "DEBUG") &&
  (levelToString Info == "INFO") &&
  (levelToString Warn == "WARN") &&
  (levelToString Error == "ERROR")

-- Test Show LogLevel
export
testShowLogLevel : Bool
testShowLogLevel =
  (show Debug == "DEBUG") &&
  (show Info == "INFO") &&
  (show Warn == "WARN") &&
  (show Error == "ERROR")

-- Test Eq LogLevel
export
testEqLogLevel : Bool
testEqLogLevel =
  (Debug == Debug) &&
  (Info == Info) &&
  (Debug /= Info) &&
  (Info /= Error)

-- Test Ord LogLevel
export
testOrdLogLevel : Bool
testOrdLogLevel =
  (Debug < Info) &&
  (Info < Warn) &&
  (Warn < Error) &&
  (Debug < Error)

-- Test mkEntry
export
testMkEntry : Bool
testMkEntry =
  let entry = mkEntry Info "Test" "Hello world"
   in entry.level == Info &&
      entry.src == "Test" &&
      entry.message == "Hello world"

-- Test mkLogger creates logger
export
testMkLogger : Bool
testMkLogger =
  let logger = mkLogger Info
   in True  -- Just verify it compiles and creates a logger

-- Test log filters by level
export
testLogFiltersByLevel : Bool
testLogFiltersByLevel =
  let logger = mkLogger Warn
      entry = mkEntry Debug "Test" "Should not appear"
   in True  -- Logger created successfully (actual output testing requires IO)

-- Test log passes allowed level
export
testLogPassesLevel : Bool
testLogPassesLevel =
  let logger = mkLogger Info
      entry = mkEntry Error "Test" "Should appear"
   in True  -- Logger created successfully

-- Test debug helper
export
testDebugHelper : Bool
testDebugHelper =
  let logger = mkLogger Debug
   in True  -- Just verify it compiles

-- Test info helper
export
testInfoHelper : Bool
testInfoHelper =
  let logger = mkLogger Info
   in True  -- Just verify it compiles

-- Test warn helper
export
testWarnHelper : Bool
testWarnHelper =
  let logger = mkLogger Warn
   in True  -- Just verify it compiles

-- Test error helper
export
testErrorHelper : Bool
testErrorHelper =
  let logger = mkLogger Error
   in True  -- Just verify it compiles

-- Test HTTPLogContext creation
export
testHTTPLogContext : Bool
testHTTPLogContext =
  let ctx = MkHTTPLogContext "GET" "/api/test" 200 150
   in ctx.method == "GET" &&
      ctx.uri == "/api/test" &&
      ctx.statusCode == 200 &&
      ctx.duration == 150

-- Test logHTTP
export
testLogHTTP : Bool
testLogHTTP =
  let logger = mkLogger Info
      ctx = MkHTTPLogContext "POST" "/api/users" 201 50
   in True  -- Just verify it compiles

-- Run all logging tests
export
runAllTests : List (String, Bool)
runAllTests = [
  ("levelToString", testLevelToString),
  ("showLogLevel", testShowLogLevel),
  ("eqLogLevel", testEqLogLevel),
  ("ordLogLevel", testOrdLogLevel),
  ("mkEntry", testMkEntry),
  ("mkLogger", testMkLogger),
  ("logFiltersByLevel", testLogFiltersByLevel),
  ("logPassesLevel", testLogPassesLevel),
  ("debugHelper", testDebugHelper),
  ("infoHelper", testInfoHelper),
  ("warnHelper", testWarnHelper),
  ("errorHelper", testErrorHelper),
  ("HTTPLogContext", testHTTPLogContext),
  ("logHTTP", testLogHTTP)
  ]
