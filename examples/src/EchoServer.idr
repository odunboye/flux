||| Minimal standalone demo of `Flux.Core.HTTP`'s server driver, with no
||| routing or middleware involved: every request gets a bare 200 whose
||| Content-Type/Content-Length mirror what the client sent. Does *not*
||| forward `r.body` into its own response. A `Responder` is responsible
||| for its own `BodyOutcome`: since this one never touches the body at
||| all, it must `drain r.body` itself to find the connection's byte
||| stream continuing right after it - draining is what actually reads
||| (and discards) the not-otherwise-consumed body, keeping a persistent
||| connection's byte stream in sync for the next request on it. Draining
||| it a *second* time (e.g. by also referencing `r.body` in the emitted
||| response) would each read from wherever the socket cursor currently
||| sits, not replay the same bytes - so this server would end up eating
||| bytes that belong to the *next* request.
module EchoServer

import Flux.Core.HTTP

%default total

respond : Responder
respond r = Prelude.do
  emit $ case r.type of
    Nothing => hello
    Just t  => ok [("Content-Type", t), ("Content-Length", show r.length)]
  ContinueWith <$> drain r.body

covering
main : IO ()
main = do
  _ :: t <- getArgs | [] => runProg (runServerArgs respond [])
  runProg (runServerArgs respond t)
