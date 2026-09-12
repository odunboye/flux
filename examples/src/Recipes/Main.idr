||| Compose independent handlers into a small observable service.
module Recipes.Main

import Recipes.Greetings
import Recipes.Quotes
import Flux.Core.Middleware
import Flux.Core.Router
import Flux.Middleware.JSON
import Flux.Middleware.RequestId
import Flux.Middleware.Timing
import Flux.Server.Config
import Flux.Server.Health

%default covering

main : IO ()
main = do
  ids <- requestId
  let endpoints = empty
        |> get "/hello/:name" hello
        |> post "/quotes" quote
        -- No dependencies in this stateless service. A DB-backed service must
        -- register a real dependency check before treating /ready as DB readiness.
        |> healthRoutes emptyRegistry "use-cases-1"
  let service = app
        |> withErrorRenderer jsonErrorRenderer
        |> use timing
        |> useAfter responseTime
        -- Always middleware also runs on errors. Never log request bodies or
        -- Authorization headers when adding an access logger.
        |> useAlways ids
        |> useAlways secureHeaders
        |> withRoutes endpoints
  -- Defaults to loopback; configuration is read from FLUX_SERVER_* variables.
  -- The server runtime owns signal handling and draining; no detached workers.
  config <- serverConfigFromEnv
  runProg (runServerFromConfig (runApp service) config)
