module Flux

-- Core HTTP
import public Flux.Core.HTTP

-- Routing
import public Flux.Core.Router

-- Context, handlers, middleware, App
import public Flux.Core.Middleware

-- JSON support
import public Flux.Data.JSON

-- Server-level concerns
import public Flux.Server.Config
import public Flux.Server.Logging
import public Flux.Server.Health

-- Built-in middleware
import public Flux.Middleware.RequestId
import public Flux.Middleware.Timing
import public Flux.Middleware.Cookies
import public Flux.Middleware.Session

-- Version
export
version : String
version = "0.2.0"

export
description : String
description = "A production-grade HTTP server framework for Idris2"
