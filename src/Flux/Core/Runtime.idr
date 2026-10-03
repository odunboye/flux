module Flux.Core.Runtime

import public Flux.Stream.Posix
import public Flux.Stream.Socket
import public Data.Linear.Ref1
import public System.Clock
import public System.Posix.Socket
import public System.Posix.Signal
import Flux.Async.Runner

%default total

-- Source compatibility for handler signatures; execution uses only Task.
public export
0 Poll : Type
Poll = ()

public export
0 Async : Type -> List Type -> Type -> Type
Async _ = Task

public export
0 AsyncPull : Type -> Type -> List Type -> Type -> Type
AsyncPull _ = Pull Task

public export
0 AsyncStream : Type -> List Type -> Type -> Type
AsyncStream _ = Stream Task

export
(.ms) : Integer -> Clock Duration
(.ms) n = makeDuration (n `div` 1000) ((n `mod` 1000) * 1000000)

export
(.s) : Integer -> Clock Duration
(.s) n = makeDuration n 0

export
sleep : Clock Duration -> Task es ()
sleep duration = Flux.Async.Core.sleep (cast (seconds duration * 1000 + nanoseconds duration `div` 1000000))
