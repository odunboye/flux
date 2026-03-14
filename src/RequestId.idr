module RequestId

import public Middleware
import public HTTP
import Data.SortedMap

%default total

-- Request ID header name
export
requestIdHeader : String
requestIdHeader = "X-Request-ID"

-- Response header name for request ID
export
responseIdHeader : String
responseIdHeader = "X-Request-ID"

-- Generate a unique request ID
-- In production, use UUID or similar
export
generateRequestId : IO String
generateRequestId = pure "req-unknown"  -- Placeholder - would use proper ID generation in production

-- Request ID middleware
-- Adds X-Request-ID to request and response
export
requestId : Middleware
requestId ctx =
  let existingId = lookup requestIdHeader ctx.request.headers
      ctxWithId = case existingId of
        Just id => ctx  -- Use existing ID from request
        Nothing =>
          -- Generate new ID (in real impl, would need IO)
          -- For now, use a placeholder
          setHeader requestIdHeader "generated-id" ctx
   in setHeader responseIdHeader (fromMaybe "unknown" existingId) ctxWithId

-- Get request ID from context
export
getRequestId : Context -> Maybe String
getRequestId ctx = lookup requestIdHeader ctx.request.headers

-- Request ID with custom generator
export
requestIdWith : IO String -> Middleware
requestIdWith gen ctx =
  let existingId = lookup requestIdHeader ctx.request.headers
   in case existingId of
        Just _ => ctx  -- Use existing ID
        Nothing =>
          -- Note: Can't call IO here in pure middleware
          -- Would need to restructure middleware type
          setHeader requestIdHeader "generated-id" ctx

-- Request ID context key
export
requestIdKey : String
requestIdKey = "requestId"

-- Request ID middleware that stores in context state
export
requestIdWithState : Middleware
requestIdWithState ctx =
  let mbId = lookup requestIdHeader ctx.request.headers
      ctx' = case mbId of
        Just id => setState requestIdKey id ctx
        Nothing => ctx
   in maybe ctx' (\id => setHeader responseIdHeader id ctx') mbId

-- Get request ID from context state
export
getRequestIdFromState : Context -> Maybe String
getRequestIdFromState ctx = getState requestIdKey ctx
