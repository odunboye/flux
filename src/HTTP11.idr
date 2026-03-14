module HTTP11

import Data.Vect
import HTTP


%default total


response : Maybe Request -> HTTPPull ByteString Bool
response Nothing  = pure False
response (Just r) = cons resp (r.body $> True)
  where
    resp : ByteString
    resp = case r.type of
      Nothing => hello
      Just t  => ok [("Content-Type",t),("Content-Length",show r.length)]

echo :
     Socket AF_INET
  -> HTTPPull ByteString (Maybe Request)
  -> AsyncPull Poll Void [Errno] Bool
echo cli p =
  extractErr HTTPErr (writeTo cli (p >>= response)) >>= \case
    Left _  => (emit badRequest |> writeTo cli) $> False
    Right b => pure b

covering
serve : Socket AF_INET -> Async Poll [] ()
serve cli = Prelude.do
  sc <- newScope
  guarantee (tillFalse sc) (close' cli)

  where
    covering
    tillFalse : Scope (Async Poll) -> Async Poll [] ()
    tillFalse sc =
      pullIn sc (bytes cli 0xff |> request |> echo cli) >>= \case
        Succeeded False => pure ()
        Succeeded True  => cede >> tillFalse sc
        Error (Here x)  => stderrLn "\{x}"
        Canceled        => pure ()

addr : Bits16 -> IP4Addr
addr = IP4 [127,0,0,1]

covering
echoSrv : Bits16 -> (n : Nat) -> (0 p : IsSucc n) => Prog [Errno] Void
echoSrv port n =
  foreachPar n serve (acceptOn AF_INET SOCK_STREAM (HTTP11.addr port))

covering
prog : List String -> Prog [Errno] Void
prog ["server", port, n] =
  case cast {to = Nat} n of
    S k => echoSrv (cast port) (S k)
    0   => echoSrv (cast port) 128
prog _ = echoSrv 2223 128

covering
main : IO ()
main = do
  _ :: t <- getArgs | [] => runProg (prog [])
  runProg (prog t)
