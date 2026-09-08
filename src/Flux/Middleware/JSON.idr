||| Flux-specific glue between `json-simple` (the `JSON`/`ToJSON`/
||| `FromJSON`/`encode`/`decode` value type and interfaces themselves -
||| import `JSON.Simple`/`JSON.Simple.Derive` directly for those, the
||| same way any other `json-simple` user would) and Flux's own
||| `Context`/`Request`/`ErrorRenderer` types.
|||
||| This module used to be `Flux.Data.JSON`, a small, dependency-free,
||| hand-rolled JSON value type and recursive-descent parser/encoder.
||| That parser had three compounding bugs (multi-key objects and
||| multi-element arrays never parsed past their first entry, and every
||| decoded string came out reversed - see git history), found and
||| fixed the hard way while building `readBody`, and even fixed
||| remained unhardened against adversarial input (no depth limit - a
||| deeply-nested payload could exhaust the native call stack, since it
||| was plain recursive descent). `json-simple` (built on `ilex-json`, a
||| real DFA-based lexer - both from the same author as the rest of this
||| project's dependency stack) is a strictly better foundation:
||| elaborator-derived `ToJSON`/`FromJSON` instances instead of hand-
||| written ones, `JInteger`/`JDouble` instead of one `Double` losing
||| integer precision, real `\uXXXX` Unicode escape handling, and a
||| stack-based (not natively-recursive) parser - confirmed directly
||| (not assumed) to parse a 100,000-level-deep nested array without
||| crashing, before this module was rewritten against it.
module Flux.Middleware.JSON

import public JSON.Simple
import public Flux.Core.HTTP
import public Flux.Core.Middleware

%default total

-- Raw HTTP helpers (standalone, outside the Context/App pipeline)
export
jsonResponse : ToJSON a => a -> ByteString
jsonResponse a =
  let bodyStr := encode a
      body    := fromString bodyStr
      hs      := [("Content-Type", "application/json"), ("Content-Length", show (length bodyStr))]
      header  := encodeResponse 200 hs
   in fastConcat [header, body]

export
jsonError : Nat -> String -> ByteString
jsonError code msg =
  let bodyStr := encode (JObject [("error", JString msg)])
      body    := fromString bodyStr
      hs      := [("Content-Type", "application/json"), ("Content-Length", show (length bodyStr))]
      header  := encodeResponse code hs
   in fastConcat [header, body]

-- Context helpers: set the response body/headers to a JSON value.
export
sendJSON : ToJSON a => a -> Context -> Context
sendJSON a = setHeader "Content-Type" "application/json" . send (fromString (encode a))

export
sendJSONError : Nat -> String -> Context -> Context
sendJSONError code msg =
  setStatus code . sendJSON (JObject [("error", JString msg)])

||| An `ErrorRenderer` (see `Flux.Core.Middleware.App.onError`) that renders
||| a caught `AppError` as a JSON `{"error": "..."}` body instead of the
||| plain-text `defaultErrorRenderer`. Register with `withErrorRenderer`.
export
jsonErrorRenderer : ErrorRenderer
jsonErrorRenderer err = sendJSONError err.status err.message

-- Content type helper
export
isJSON : Request -> Bool
isJSON req =
  case req.type of
    Just "application/json" => True
    Just "application/json; charset=utf-8" => True
    _                       => False
