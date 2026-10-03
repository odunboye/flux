module Main

import Flux

%default covering

okHandler : Handler
okHandler = pure . sendText "ok"

echoHeader : Handler
echoHeader ctx = do
  Right body <- readBody 1024 ctx
    | Left _ => pure (setStatus 400 ctx)
  pure $ setHeader "X-Echo" (Data.ByteString.toString body) (sendText "ok" ctx)

doubleRead : Handler
doubleRead ctx = do
  Right first <- readBody 1024 ctx
    | Left _ => pure (setStatus 400 ctx)
  Right second <- readBody 1024 ctx
    | Left _ => pure (setStatus 400 ctx)
  pure $ sendText (Data.ByteString.toString first ++ "|" ++ Data.ByteString.toString second) ctx

finalize : Middleware
finalize ctx = case getQuery "mode" ctx.request of
  Just "304" => pure (setStatus 304 ctx)
  Just "error" => throw (MkAppError 500 "after hook failed")
  _ => pure ctx

conditionalFailure : Middleware
conditionalFailure ctx = case getQuery "failAlways" ctx.request of
  Just _ => throw (MkAppError 500 "always hook failed")
  _ => pure ctx

main : IO ()
main = do
  cfg <- serverConfigFromEnv
  let routes = empty
        |> get "/" okHandler
        |> get "/file/*path" (staticHandler "public" defaultMimeFor)
        |> head_ "/file/*path" (staticHandler "public" defaultMimeFor)
        |> post "/echo-header" echoHeader
        |> post "/double-read" doubleRead
      application = app
        |> withRoutes routes
        |> useAfter finalize
        |> useAlways secureHeaders
        |> useAlways conditionalFailure
        |> useAlways (pure . setHeader "X-Last-Hook" "ran")
  runProg (runServerFromConfig (runApp application) cfg)
