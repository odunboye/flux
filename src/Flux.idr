module Flux

-- Core HTTP
import public Flux.Core.HTTP

-- Routing
import public Flux.Core.Router

-- Context, handlers, middleware, App
import public Flux.Core.Middleware

-- JSON support: the value type/ToJSON/FromJSON/encode/decode come
-- straight from json-simple; Flux.Middleware.JSON is just the glue
-- (sendJSON, jsonErrorRenderer, isJSON) tying it to Context/Request.
import public JSON.Simple
import public Flux.Middleware.JSON

-- Server-level concerns
import public Flux.Server.Config
import public Flux.Server.Logging
import public Flux.Server.Health

-- Built-in middleware
import public Flux.Middleware.RequestId
import public Flux.Middleware.Timing
import public Flux.Middleware.Cookies
import public Flux.Middleware.Session
import public Flux.Middleware.Static

-- Version
export
version : String
version = "0.2.0"

export
description : String
description = "A production-grade HTTP server framework for Idris2"
