||| Opt-in exact-origin CORS for bearer-only JSON RPC applications.
||| CORS is a browser policy, not authentication. Do not use wildcard origins.
module Flux.Middleware.RpcCors

import public Flux.Core.Middleware
import Data.List
import Data.List1
import Data.String

%default covering

validHost : String -> Bool
validHost host = length host <= 253 && all validLabel (forget (split (== '.') host))
  where
    validLabel : String -> Bool
    validLabel label = label /= "" && length label <= 63 && not (isPrefixOf "-" label) &&
      not (isSuffixOf "-" label) && all (\c => (c >= 'a' && c <= 'z') ||
        (c >= '0' && c <= '9') || c == '-') (unpack label)

||| Conservative origins: Capacitor's iOS origin or HTTPS DNS/IPv4 authorities.
||| No wildcards, opaque origins, credentials, paths, queries or fragments.
export
validRpcOrigin : String -> Bool
validRpcOrigin origin = origin == "capacitor://localhost" ||
  (isPrefixOf "https://" origin && case forget (split (== ':') (substr 8 (length origin) origin)) of
    [host] => validHost host
    [host, port] => let number : Integer = cast port in
      validHost host && number > 0 && number <= 65535 && number /= 443 && show number == port
    _ => False)

rpc : Context -> Bool
rpc ctx = isPrefixOf "/rpc/v1/" ctx.request.uri

allowed : List String -> Context -> Bool
allowed origins ctx = case lookup "origin" ctx.request.headers of
  Just origin => elem origin origins
  Nothing => False

preflight : Context -> Bool
preflight ctx = ctx.request.method == OPTIONS &&
  lookup "access-control-request-method" ctx.request.headers == Just "POST" &&
  case lookup "access-control-request-headers" ctx.request.headers of
    Nothing => True
    Just headers => all (\header => elem (toLower (trim header)) ["authorization", "content-type"])
                        (forget (split (== ',') headers))

||| Install with `use`. An empty policy preserves ordinary same-origin behavior.
||| If enabled, Origin-bearing RPCs from other origins fail before dispatch.
export
rpcOriginGuard : List String -> Middleware
rpcOriginGuard origins ctx =
  if null origins || not (rpc ctx) then pure ctx else
    case lookup "origin" ctx.request.headers of
      Nothing => pure ctx -- Non-browser clients still require bearer auth.
      Just origin => if not (elem origin origins) ||
                        (ctx.request.method == OPTIONS && not (preflight ctx))
        then throw (MkAppError 403 "RPC origin or preflight is not allowed")
        else pure ctx

||| Install with `useAlways`, so allowed clients can read 401/error responses.
||| Valid OPTIONS is answered without invoking any POST handler or authorizer.
export
rpcCorsHeaders : List String -> Middleware
rpcCorsHeaders origins ctx = if null origins || not (rpc ctx) then pure ctx else
  let previous = fromMaybe "" (lookup "Vary" ctx.respHeaders)
      varied = setHeaders [("Vary", (if previous == "" then "" else previous ++ ", ") ++
                          "Origin, Access-Control-Request-Method, Access-Control-Request-Headers"),
                           ("Cache-Control", "no-store")] ctx in
    if not (allowed origins ctx) then pure varied else
      let headers = setHeaders [("Access-Control-Allow-Origin", fromMaybe "" (lookup "origin" ctx.request.headers)),
                                ("Access-Control-Allow-Methods", "POST"),
                                ("Access-Control-Allow-Headers", "Authorization, Content-Type")] varied in
        if preflight ctx && elem ctx.statusCode [200, 204, 404, 405]
          then pure (setStatus 204 (sendText "" headers))
          else pure headers
