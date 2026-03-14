module Flux

-- Core HTTP
import HTTP

-- Routing
import Router

-- Middleware
import Middleware

-- Logging
import Logging

-- JSON support
import JSON

-- Production modules
import Config
import RequestId
import Timing
import Health

-- Version
export
version : String
version = "0.2.0"

export
description : String
description = "A production-grade HTTP server framework for Idris2"
