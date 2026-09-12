||| Use case: typed JSON input, bounded bodies and domain validation.
||| This computes a demonstration quote; it does not charge or persist anything.
module Recipes.Quotes

import Flux.Core.Middleware
import Flux.Middleware.JSON
import JSON.Simple
import JSON.Simple.Derive

%default covering
%language ElabReflection

record QuoteRequest where
  constructor MkQuoteRequest
  quantity : Integer
  unitPriceCents : Integer

%runElab derive "QuoteRequest" [FromJSON]

record QuoteResponse where
  constructor MkQuoteResponse
  quantity : Integer
  totalCents : Integer

%runElab derive "QuoteResponse" [ToJSON]

export
quote : Handler
quote ctx = do
  unless (isJSON ctx.request)
    (throw (MkAppError 415 "Expected application/json"))
  request <- requireJsonBody {a = QuoteRequest} 2048
    "Expected integer quantity and unitPriceCents" ctx
  unless (request.quantity >= 1 && request.quantity <= 1000)
    (throw (MkAppError 400 "Quantity must be between 1 and 1000"))
  unless (request.unitPriceCents >= 0 && request.unitPriceCents <= 1000000)
    (throw (MkAppError 400 "Unit price must be between 0 and 1000000 cents"))
  -- Integer minor units avoid floating-point rounding. The limits also keep
  -- this example's JSON numbers within JavaScript's exact integer range.
  pure (sendJSON (MkQuoteResponse request.quantity
    (request.quantity * request.unitPriceCents)) ctx)
