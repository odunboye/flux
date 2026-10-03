# Exact-origin JSON RPC CORS

`Flux.Middleware.RpcCors` is opt-in middleware for bearer-only applications:

```idris
app |> use (rpcOriginGuard origins)
    |> useAlways (rpcCorsHeaders origins)
```

Validate deployment values with `validRpcOrigin` before constructing the app.
Supported values are `capacitor://localhost` and exact lowercase HTTPS DNS/IPv4
origins (including a non-default port). No wildcard, opaque `null`, userinfo,
path, query, fragment or HTTP origin is accepted by that configuration helper.
IPv6 origin allowlist entries are not supported by the initial helper.

The guard rejects unapproved Origin-bearing `/rpc/v1/` requests **before** route
dispatch. Valid preflight permits POST and only Authorization/Content-Type;
OPTIONS never invokes POST handlers. The always hook supplies exact-origin
headers on successes and errors (including 401), sets no-store and varies on
Origin/preflight headers. It never permits credentials/cookies or emits `*`.

An empty list preserves ordinary same-origin web behavior and emits no CORS
approval. When enabled, include the served web application's HTTPS origin too
if it should continue making same-origin POSTs. No Host/forwarded-header trust is
used to manufacture an allowed origin. Clients without Origin remain possible;
**CORS is not authentication**, and bearer verification must remain on every
private RPC. Never replace authorization/ownership checks with this middleware.

The backend still needs HTTPS termination and private/restricted access to its
unencrypted upstream socket. CORS neither supplies TLS nor makes a publicly
exposed HTTP API safe. Do not enable wildcard proxy CORS in front of this policy.

The core test suite includes allowed preflight, blocked origin/method/header,
no-dispatch denial, readable 401 responses and disabled-policy compatibility.
