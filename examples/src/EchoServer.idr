||| Minimal standalone demo of `Flux.Core.HTTP`'s server driver, with no
||| routing or middleware involved: every request gets a bare 200 whose
||| Content-Type/Content-Length mirror what the client sent.
module EchoServer

import Flux.Core.HTTP

%default total

respond : Request -> HTTPProg ByteString
respond r = pure $ case r.type of
  Nothing => hello
  Just t  => ok [("Content-Type", t), ("Content-Length", show r.length)]

covering
main : IO ()
main = do
  _ :: t <- getArgs | [] => runProg (runServerArgs respond [])
  runProg (runServerArgs respond t)
