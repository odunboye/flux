||| Minimal standalone demo of `Flux.Core.HTTP`'s server driver, with no
||| routing or middleware involved: every request gets a bare 200 whose
||| Content-Type/Content-Length mirror what the client sent. Does *not*
||| forward `r.body` into its own response - `respondWith` (the shared
||| driver) always drains whatever's left of the request body itself
||| after a `Responder` runs, exactly once, to keep a persistent
||| connection's byte stream in sync for the next request on it;
||| referencing `r.body` here too would drain it a second time, each
||| drain reading from wherever the socket cursor currently sits, so this
||| server would end up eating bytes that belong to the *next* request.
module EchoServer

import Flux.Core.HTTP

%default total

respond : Responder
respond r = emit $ case r.type of
  Nothing => hello
  Just t  => ok [("Content-Type", t), ("Content-Length", show r.length)]

covering
main : IO ()
main = do
  _ :: t <- getArgs | [] => runProg (runServerArgs respond [])
  runProg (runServerArgs respond t)
