module TestHealth

import Flux.Server.Health
import Data.SortedMap

%default covering

-- overallStatus

export
testOverallStatusEmptyIsHealthy : Bool
testOverallStatusEmptyIsHealthy = overallStatus [] == Healthy

export
testOverallStatusUnhealthyWins : Bool
testOverallStatusUnhealthyWins =
  overallStatus
    [ MkCheckResult "a" Healthy Nothing
    , MkCheckResult "b" Unhealthy Nothing
    , MkCheckResult "c" Degraded Nothing
    ] == Unhealthy

export
testOverallStatusDegradedWithoutUnhealthy : Bool
testOverallStatusDegradedWithoutUnhealthy =
  overallStatus [MkCheckResult "a" Healthy Nothing, MkCheckResult "b" Degraded Nothing] == Degraded

-- mkHealthStatus

export
testEmptyRegistryIsHealthy : IO Bool
testEmptyRegistryIsHealthy = do
  status <- mkHealthStatus emptyRegistry "1.0.0"
  pure (status.status == Healthy && length status.checks == 0)

-- The whole reason mkHealthStatus.timestamp was worth fixing: it used
-- to be hardcoded to 0 regardless of when the check actually ran.
export
testTimestampIsReal : IO Bool
testTimestampIsReal = do
  status <- mkHealthStatus emptyRegistry "1.0.0"
  -- Any real Unix timestamp from this decade comfortably exceeds this -
  -- 0 (the old hardcoded value) very much does not.
  pure (status.timestamp > 1_700_000_000)

-- parseVmRSSKb: the one piece of memoryCheck's logic that's portable
-- and doesn't depend on the host actually having /proc.

export
testParseVmRSSKbValid : Bool
testParseVmRSSKbValid =
  parseVmRSSKb "Name:\tbash\nVmRSS:\t    12345 kB\nVmSize:\t 999 kB\n" == Just 12345

export
testParseVmRSSKbMissing : Bool
testParseVmRSSKbMissing = parseVmRSSKb "Name:\tbash\nVmSize:\t 999 kB\n" == Nothing

export
testParseVmRSSKbMalformed : Bool
testParseVmRSSKbMalformed = parseVmRSSKb "Name:\tbash\nVmRSS:\tnot-a-number\n" == Nothing

-- memoryCheck: real logic, but the host may or may not actually have
-- /proc/self/status (Linux does; Darwin doesn't) - written to hold on
-- either, since it exercises real behavior on both: Degraded is only
-- ever acceptable as "couldn't get a real answer", never as a
-- substitute for a threshold verdict the check was actually able to
-- compute.

export
testMemoryCheckNeverFalselyUnhealthy : IO Bool
testMemoryCheckNeverFalselyUnhealthy = do
  result <- memoryCheck 999999999  -- no real process RSS could exceed this
  pure $ result.name == "memory" &&
    case result.status of
      Unhealthy => False  -- would mean the threshold comparison itself is broken
      _         => True   -- Healthy (real check, under threshold) or Degraded (unsupported here)

export
testMemoryCheckFlagsOverThreshold : IO Bool
testMemoryCheckFlagsOverThreshold = do
  result <- memoryCheck 0  -- any real positive RSS exceeds a 0MB threshold
  pure $ case result.status of
    Healthy => False  -- would mean the threshold comparison itself is broken
    _       => True   -- Unhealthy (real check, correctly over threshold) or Degraded (unsupported here)

-- Run all health tests
export
runAllTests : IO (List (String, Bool))
runAllTests = do
  emptyHealthy    <- testEmptyRegistryIsHealthy
  timestampReal   <- testTimestampIsReal
  memNeverFalse   <- testMemoryCheckNeverFalselyUnhealthy
  memOverThresh   <- testMemoryCheckFlagsOverThreshold
  pure
    [ ("overallStatusEmptyIsHealthy", testOverallStatusEmptyIsHealthy)
    , ("overallStatusUnhealthyWins", testOverallStatusUnhealthyWins)
    , ("overallStatusDegradedWithoutUnhealthy", testOverallStatusDegradedWithoutUnhealthy)
    , ("emptyRegistryIsHealthy", emptyHealthy)
    , ("timestampIsReal", timestampReal)
    , ("parseVmRSSKbValid", testParseVmRSSKbValid)
    , ("parseVmRSSKbMissing", testParseVmRSSKbMissing)
    , ("parseVmRSSKbMalformed", testParseVmRSSKbMalformed)
    , ("memoryCheckNeverFalselyUnhealthy", memNeverFalse)
    , ("memoryCheckFlagsOverThreshold", memOverThresh)
    ]
