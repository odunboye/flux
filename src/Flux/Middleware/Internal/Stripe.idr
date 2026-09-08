||| Sharding helpers used to spread concurrent read-modify-write traffic
||| across several independent mutable cells instead of one contended
||| global one.
|||
||| A single `Data.Linear.Ref1` reference updated via `update`/`mod` is
||| already lock-free (see `RequestId`/`Session`'s earlier fix), but
||| "lock-free" only means no thread blocks in the kernel waiting for
||| it - every request still has to CAS-retry against the exact same
||| cache line. Under real concurrency (many worker threads, each
||| running requests genuinely in parallel) that cache line gets
||| hammered by every core at once, and the resulting coherency traffic
||| can dominate over whatever the request was actually doing. Splitting
||| the state into several independent cells ("stripes") and picking a
||| different one per request spreads that cost across several cache
||| lines instead.
module Flux.Middleware.Internal.Stripe

import Data.Linear.Ref1
import Data.Fin
import Data.Vect
import System.Clock

%default total

||| Number of stripes to use, fixed rather than tied to
||| `IDRIS2_ASYNC_THREADS` (application code has no way to query the
||| async runtime's worker-thread count) - chosen to comfortably exceed
||| any realistic thread count for this kind of server.
|||
||| Kept as a plain `Nat` only for reference/display; every actual use
||| below is the literal `16` (as `Vect 16`/`Fin 16`/`restrict 15`)
||| rather than this name, since a named `Nat` constant doesn't reduce
||| to the `S _` shape Idris needs to unify against `Fin`/`Vect` index
||| types. If you change the stripe count, update all of them together.
export
stripeCount : Nat
stripeCount = 16

||| 16 independently allocated mutable cells, each starting at `v`.
|||
||| Deliberately not `Data.Vect.replicate`, which would share a single
||| cell 16 times over - each stripe needs its own backing memory, or
||| sharding wouldn't reduce contention at all.
export
newStripes : a -> IO (Vect 16 (Ref World a))
newStripes v = traverse (\_ => newref v) (Vect.replicate 16 ())

||| Picks a stripe index cheaply and without touching any shared mutable
||| state: the sub-second nanosecond component of a fresh monotonic
||| clock reading. This doesn't need to be uniformly random, only
||| decorrelated enough that concurrently-running requests on different
||| worker threads don't keep piling onto the same stripe - reading the
||| clock never contends between threads the way a shared round-robin
||| cursor would (that would just relocate the contention, not remove
||| it).
|||
||| Use this to pick a stripe for something with no natural key of its
||| own, e.g. a plain counter increment.
export
randomStripe : IO (Fin 16)
randomStripe = do
  t <- clockTime Monotonic
  pure (restrict 15 (nanoseconds t))

||| Picks a stripe index deterministically from a key (e.g. a session
||| ID): the same key always lands on the same stripe. Needed whenever a
||| later lookup must find data that an earlier - possibly
||| differently-`randomStripe`-d - request wrote under the same key.
|||
||| Not a cryptographic hash, just enough to spread keys evenly across
||| stripes; collisions between different keys landing on the same
||| stripe are expected and harmless (they just share a cell).
export
keyStripe : String -> Fin 16
keyStripe s =
  restrict 15 (cast (foldl (\acc, c => acc * 31 + cast (ord c)) 0 (unpack s)))
