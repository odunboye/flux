module Main

import Protocol
import Flux
import Data.SortedMap
import System

%default covering

-- Test fixture ONLY: these literal credentials are not a session implementation.
-- runServerArgs binds loopback; this executable must never be deployed.
resolveFixture : Authenticator
resolveFixture request = case lookup "authorization" request.headers of
  Just "Bearer fixture-a" => pure (Just (MkPrincipal "user-a"))
  Just "Bearer fixture-b" => pure (Just (MkPrincipal "user-b"))
  Just "Bearer broken-store" => throw (MkAppError 500 "secret database diagnostic")
  _ => pure Nothing

privateProbe : Principal -> ProbeRequest -> AppProg ProbeResponse
privateProbe principal input = pure (MkProbeResponse principal.subjectId)

publicProbe : ProbeRequest -> AppProg ProbeResponse
publicProbe input = pure (MkProbeResponse "public")

main : IO ()
main = do
  args <- getArgs
  let api = MkApi privateProbe publicProbe
  let application = app |> withErrorRenderer rpcErrorRenderer
                        |> withRoutes (routes resolveFixture api)
  runProg (runServerArgs (runApp application) (drop 1 args))
