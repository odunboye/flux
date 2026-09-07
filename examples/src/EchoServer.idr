||| Minimal standalone demo of `Flux.Core.HTTP`'s server driver, with no
||| routing or middleware involved: every request gets a bare 200 whose
||| Content-Type/Content-Length mirror what the client sent, followed by
||| an echo of the request body (a `Responder` builds the whole wire
||| response itself, so this echoing is explicit here rather than
||| something the shared driver does for every responder).
module EchoServer

import Flux.Core.HTTP

%default total

respond : Responder
respond r =
  let resp := case r.type of
        Nothing => hello
        Just t  => ok [("Content-Type", t), ("Content-Length", show r.length)]
   in emit resp >> r.body

covering
main : IO ()
main = do
  _ :: t <- getArgs | [] => runProg (runServerArgs respond [])
  runProg (runServerArgs respond t)
