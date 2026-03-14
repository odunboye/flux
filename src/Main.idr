module Main

import HTTP
import Router
import Middleware
import Examples
import FS.Socket
import IO.Async.Loop.Posix
import System

%language ElabReflection

-- Re-use the pattern from HTTP.idr
response : Maybe Request -> HTTPStream ByteString
response Nothing  = pure ()
response (Just r) = cons resp r.body
  where
    resp : ByteString
    resp = handleRoute appRouter r

echo :
     Socket AF_INET
  -> HTTPPull ByteString (Maybe Request)
  -> AsyncStream Poll [Errno] Void
echo cli p =
  extractErr HTTPErr (writeTo cli (p >>= response)) >>= \case
    Left _   => emit badRequest |> writeTo cli
    Right () => pure ()

covering
serve : Socket AF_INET -> Async Poll [] ()
serve cli =
  flip guarantee (close' cli) $
    mpull $ handleErrors (\(Here x) => stderrLn "\{x}") $
         bytes cli 0xfff
      |> request
      |> echo cli

covering
server : Bits16 -> (n : Nat) -> (0 p : IsSucc n) => Prog [Errno] Void
server port n =
  foreachPar n serve (acceptOn AF_INET SOCK_STREAM (HTTP.addr port))

covering
prog : List String -> Prog [Errno] Void
prog ["server", port, n] =
  case cast {to = Nat} n of
    S k => server (cast port) (S k)
    0   => server (cast port) 128
prog _ = server 8080 128

covering
main : IO ()
main = do
  _ :: t <- getArgs | [] => runProg (prog [])
  runProg (prog t)
