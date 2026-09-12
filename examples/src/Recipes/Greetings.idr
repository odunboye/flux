||| Use case: a small public HTTP API with path and query parameters.
module Recipes.Greetings

import Flux.Core.Middleware
import Flux.Core.Router
import Flux.Middleware.JSON
import JSON.Simple

%default covering

export
hello : Handler
hello ctx = do
  Just name <- pure (getParam "name" ctx.pathParams)
    | Nothing => throw (MkAppError 400 "A name is required")
  unless (name /= "" && length name <= 80)
    (throw (MkAppError 400 "Name must contain 1 to 80 characters"))
  let language = fromMaybe "en" (getQuery "language" ctx.request)
  greeting <- case language of
    "en" => pure "Hello"
    "es" => pure "Hola"
    _ => throw (MkAppError 400 "Supported languages: en, es")
  pure (sendJSON (JObject [("message", JString (greeting ++ ", " ++ name ++ "!"))]) ctx)
