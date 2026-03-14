module Logging

import public System
import public System.File

%default total

-- Log levels
public export
data LogLevel = Debug | Info | Warn | Error

export
Show LogLevel where
  showPrec _ Debug = "DEBUG"
  showPrec _ Info  = "INFO"
  showPrec _ Warn  = "WARN"
  showPrec _ Error = "ERROR"

export
Eq LogLevel where
  Debug == Debug = True
  Info  == Info  = True
  Warn  == Warn  = True
  Error == Error = True
  _     == _     = False

export
Ord LogLevel where
  compare Debug Debug = EQ
  compare Debug _     = LT
  compare Info Debug  = GT
  compare Info Info   = EQ
  compare Info _      = LT
  compare Warn Error  = LT
  compare Warn Warn   = EQ
  compare Warn _      = GT
  compare Error Error = EQ
  compare Error _     = GT

export
levelToString : LogLevel -> String
levelToString Debug = "DEBUG"
levelToString Info  = "INFO"
levelToString Warn  = "WARN"
levelToString Error = "ERROR"

-- Log entry
public export
record LogEntry where
  constructor MkLogEntry
  level     : LogLevel
  src       : String
  message   : String

export
mkEntry : LogLevel -> String -> String -> LogEntry
mkEntry lvl src msg = MkLogEntry lvl src msg

-- Logger
public export
Logger : Type
Logger = LogLevel -> String -> String -> IO ()

export
mkLogger : LogLevel -> Logger
mkLogger minLevel lvl src msg =
  if lvl >= minLevel then
    putStrLn ("[" ++ levelToString lvl ++ "] [" ++ src ++ "] " ++ msg)
  else
    pure ()

export
log : Logger -> LogEntry -> IO ()
log logger entry = logger entry.level entry.src entry.message

-- Convenience logging functions
export
debug : Logger -> String -> String -> IO ()
debug logger src msg = logger Debug src msg

export
info : Logger -> String -> String -> IO ()
info logger src msg = logger Info src msg

export
warn : Logger -> String -> String -> IO ()
warn logger src msg = logger Warn src msg

export
error : Logger -> String -> String -> IO ()
error logger src msg = logger Error src msg

-- HTTP request logging
public export
record HTTPLogContext where
  constructor MkHTTPLogContext
  method      : String
  uri         : String
  statusCode  : Nat
  duration    : Integer

export
logHTTP : Logger -> HTTPLogContext -> IO ()
logHTTP logger ctx =
  let msg := "\{ctx.method} \{ctx.uri} -> \{show ctx.statusCode} (\{show ctx.duration}ms)"
   in info logger "HTTP" msg
