module Flux.Server.Logging

import public System
import public System.File

import Flux.Core.HTTP
import Data.Linear.Ref1
import System.Clock

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

||| Writes each log line immediately via `putStrLn`.
|||
||| Every call either lands on stdout before it returns, or the write
||| itself failed loudly - nothing is ever silently lost. That
||| immediacy has a real cost under genuine multi-thread concurrency,
||| though: every worker thread's requests all write to the *same*
||| stdout, and that contends no matter how the write itself is done
||| (see `BatchedLogger`'s doc comment for measurements). Prefer
||| `batched`/`flushLoop` for a busy server's access log; keep this for
||| anything where a missing or delayed line would be a real problem
||| (e.g. an audit trail), or for low-traffic logging where the
||| contention never matters in practice.
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

--------------------------------------------------------------------------------
-- Batched logging
--------------------------------------------------------------------------------

||| A log sink that buffers entries in memory instead of writing them
||| immediately, paired with a background loop (`flushLoop`) that
||| periodically drains that buffer in one batched write - taking
||| logging off the request-handling hot path entirely, unlike
||| `mkLogger`, which writes directly on every call and becomes the
||| whole server's bottleneck under genuine multi-thread concurrency
||| (benchmarked: a request-ID+session-only middleware stack hit 22.4k
||| req/s at 4 async worker threads; adding one `mkLogger` call per
||| request back in dropped that to 484 - not the counters this used to
||| be about, see `Flux.Middleware.RequestId`/`Flux.Middleware.Session`'s
||| striping fix - a single shared stdout is the bottleneck once more
||| than one worker thread is genuinely running requests in parallel).
|||
||| An earlier version of this doc comment reported a reproducible
||| crash here ("Exception: invalid memory reference") under `wrk
||| -t4 -c100` load. Chasing it down further, it did not reproduce
||| from a clean build - a dozen further clean-rebuild-and-load-test
||| cycles (single string, `SnocList`, striped and unstriped, `wrk` up
||| to `-t8 -c200 -d20s`) never hit it again. The most likely
||| explanation is a stale/inconsistent build artifact from rapid
||| edit-rebuild-run cycles against the same local package override
||| while first tracking it down - `pack` resolving a locally-overridden
||| dependency to a mismatched cached install is a real, previously
||| confirmed failure mode in this same investigation (see the
||| `idris2-async` fork's round-robin-scheduler fix notes), not
||| something specific to this file. Treat that as the working
||| explanation unless it reproduces again from a genuinely clean
||| build; if it does, the earlier isolation notes (now removed from
||| here, see git history) are the place to pick back up.
|||
||| What *is* still real: throughput here is well below the 22.4k
||| ceiling a striped counter alone gets (measured as low as ~300-500
||| req/s at 2-4 worker threads under sustained `wrk` load) - `buffer`
||| is a single shared cell, and every request's `mod` call CAS-retries
||| against the same cache line the same way the pre-striping counters
||| did. A quick attempt at striping `buffer` the same way
||| (`Flux.Middleware.Internal.Stripe`) did not show a clean win in
||| this specific spot, unlike it did for the counters - worth
||| revisiting, but not yet understood well enough to land.
|||
||| TRADEOFF: buffered entries are lost if the process dies (crash, an
||| unhandled signal, `kill -9`, power loss) between being appended and
||| the next `flushLoop` tick - up to `interval`'s worth of the tail of
||| the log. `mkLogger` has no such window. That's an acceptable price
||| for an access log; it is very much not for anything a missing line
||| would actually matter for (an audit trail, say) - use `mkLogger`
||| there and accept its contention cost instead.
export
record BatchedLogger where
  constructor MkBatchedLogger
  minLevel : LogLevel
  buffer   : Ref World (SnocList String)

||| Creates a batched logger. On its own this does nothing but
||| accumulate - pair it with `flushLoop`, run concurrently with the
||| server (see `Flux.Core.HTTP.runProgWith`), or nothing you log will
||| ever actually reach stdout.
export
newBatchedLogger : LogLevel -> IO BatchedLogger
newBatchedLogger lvl = MkBatchedLogger lvl <$> newref [<]

||| The `Logger` view of a `BatchedLogger`, for use anywhere a plain
||| `Logger` is expected (e.g. `Flux.Middleware.Timing.requestLog`):
||| appends to `buffer` instead of writing immediately.
export
batched : BatchedLogger -> Logger
batched blogger lvl src msg =
  when (lvl >= minLevel blogger) $
    mod (buffer blogger) (\sl => sl :< ("[" ++ levelToString lvl ++ "] [" ++ src ++ "] " ++ msg))

||| Drains whatever is currently buffered and writes it out in a single
||| batched call: one `putStrLn`, however many lines it drains, instead
||| of one per line.
export
flushNow : BatchedLogger -> IO ()
flushNow blogger = do
  drained <- update (buffer blogger) (\sl => ([<], sl))
  case drained of
    [<] => pure ()
    _   => putStr (concatMap (++ "\n") (drained <>> []))

||| Runs `flushNow` forever, waiting `interval` between flushes. Race
||| this alongside the server, e.g.
||| `runProgWith [flushLoop 50.ms blogger] ...` - `runProgWith`'s doc
||| comment explains why that alone doesn't give you a *final* flush at
||| shutdown for free (a background task is canceled, not given a
||| chance to finish its current step): call `flushNow` yourself once
||| more after `runProgWith` returns to drain whatever the last tick
||| missed.
export covering
flushLoop : Clock Duration -> BatchedLogger -> Async Poll [] ()
flushLoop interval blogger = do
  sleep interval
  liftIO (flushNow blogger)
  flushLoop interval blogger

--------------------------------------------------------------------------------
-- Batched access logging (structured - format on flush, not on request)
--------------------------------------------------------------------------------

||| A log sink specialized for the per-request access log
||| (`Flux.Middleware.Timing.requestAccessLog`): appends the *raw*
||| `HTTPLogContext` on the request-handling thread, deferring string
||| formatting entirely to `flushAccessLog`, which runs on the single
||| flush-loop thread instead.
|||
||| `BatchedLogger` already takes logging off the request path by
||| buffering instead of writing directly - but `batched` still builds
||| the *formatted* line (string concatenation) on the request-handling
||| thread, before appending it, and that alone is enough to collapse
||| throughput under real concurrency. Measured directly in Chez, with
||| no Idris2/Flux/async-posix involved: a shared CAS cell appended to
||| with a built string goes 4.5M ops/sec (1 thread) -> 568K (2) ->
||| 194K (4) -> 181K (8); splitting that cell into 16 stripes barely
||| helps (4.0M -> 1.46M -> 491K -> 144K). Appending a small fixed-size
||| record instead - no string built at all - to the *same, unstriped*
||| cell goes 20.1M -> 21.0M -> 13.0M -> 4.8M: 25-90x better at every
||| thread count, and it scales going from 1 to 2 threads instead of
||| immediately collapsing. Striping never mattered; concurrent
||| *allocation* is what Chez's multi-threaded GC contends on, and a
||| built string is a much bigger, more allocation-heavy object than a
||| handful of already-existing/cheap values packaged into a record.
|||
||| `HTTPLogContext`'s fields are all already cheap to produce without
||| this: `show` on a `Method` returns an interned literal (no
||| allocation), `requestUri` is the request's own existing string (not
||| rebuilt for logging) - only `statusCode`/`duration` need packaging
||| into the record itself, which is the one allocation this can't
||| avoid, same as the benchmark above. `flushAccessLog` does the
||| `\{...}`/`++` formatting work for every drained entry at once, on
||| one thread, where building strings is fast (~5M ops/sec
||| single-threaded, from the same benchmark) - it's specifically
||| *concurrent* string-building across threads that collapses, not
||| string-building itself.
|||
||| Same TRADEOFF as `BatchedLogger`: buffered entries are lost if the
||| process dies between being appended and the next flush.
export
record BatchedAccessLog where
  constructor MkBatchedAccessLog
  entries : Ref World (SnocList HTTPLogContext)

||| Creates a batched access log. On its own this does nothing but
||| accumulate - pair it with `accessFlushLoop`, run concurrently with
||| the server (see `Flux.Core.HTTP.runProgWith`), or nothing logged
||| will ever actually reach stdout.
export
newBatchedAccessLog : IO BatchedAccessLog
newBatchedAccessLog = MkBatchedAccessLog <$> newref [<]

||| Appends the raw context - no string formatting happens here. See
||| `BatchedAccessLog`'s doc comment for why that's the entire point.
export
logAccess : BatchedAccessLog -> HTTPLogContext -> IO ()
logAccess blog ctx = mod (entries blog) (\sl => sl :< ctx)

formatAccess : HTTPLogContext -> String
formatAccess ctx =
  "[INFO] [HTTP] \{ctx.method} \{ctx.uri} -> \{show ctx.statusCode} (\{show ctx.duration}ms)"

||| Drains whatever access-log entries are currently buffered, formats
||| all of them, and writes them out in a single batched call.
export
flushAccessLog : BatchedAccessLog -> IO ()
flushAccessLog blog = do
  drained <- update (entries blog) (\sl => ([<], sl))
  case drained of
    [<] => pure ()
    _   => putStr (concatMap (\ctx => formatAccess ctx ++ "\n") (drained <>> []))

||| Runs `flushAccessLog` forever, waiting `interval` between flushes.
||| Race this alongside the server the same way as `flushLoop` - see
||| its doc comment for the shutdown-flush caveat (a background task is
||| canceled, not given a chance to finish its current step: call
||| `flushAccessLog` yourself once more after `runProgWith` returns).
export covering
accessFlushLoop : Clock Duration -> BatchedAccessLog -> Async Poll [] ()
accessFlushLoop interval blog = do
  sleep interval
  liftIO (flushAccessLog blog)
  accessFlushLoop interval blog
