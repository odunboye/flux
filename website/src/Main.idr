module Main

import Flux.Core.HTTP
import Flux.Core.Router
import Flux.Core.Middleware
import Flux.Middleware.Static
import Flux.Server.Config
import Data.SortedMap
import System

%default covering

-- Only these public assets are exposed. Never mount the repository root.
asset : String -> Handler
asset name ctx = staticHandler "public" defaultMimeFor
  ({ pathParams := MkParams (insert "path" name empty) } ctx)

headers : Middleware
headers ctx = pure $ setHeaders
  [("Content-Security-Policy", "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self'; connect-src 'none'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'; form-action 'none'")
  ,("X-Content-Type-Options", "nosniff")
  ,("Referrer-Policy", "strict-origin-when-cross-origin")
  ,("Permissions-Policy", "camera=(), microphone=(), geolocation=()")]
  ctx

main : IO ()
main = do
  let routes = empty |> get "/" (asset "index.html")
                     |> get "/site.css" (asset "site.css")
                     |> get "/site.js" (asset "site.js")
                     |> get "/mark.svg" (asset "mark.svg")
                     |> get "/health" (\ctx => pure (sendText "ok\n" ctx))
  let site = app |> useAlways headers |> withRoutes routes
  args <- getArgs
  case drop 1 args of
    ["--from-env"] => do
      config <- serverConfigFromEnv
      runProg (runServerFromConfig (runApp site) config)
    rest => runProg (runServerArgs (runApp site) rest)
