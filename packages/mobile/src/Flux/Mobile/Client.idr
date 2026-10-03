||| HTTPS-only, origin-bound RPC for packaged applications.
||| Missing mobile configuration is an error, never a same-origin fallback.
module Flux.Mobile.Client

import public Flux.Platform.Client
import public Iris.Effect.Http.Web

%default covering

%foreign "browser:lambda: () => globalThis.FluxMobile?.apiOrigin || ''"
prim__origin : PrimIO String

%foreign "browser:lambda: () => globalThis.FluxMobileTransport ? 1 : 0"
prim__ready : PrimIO Bool

%foreign "browser:lambda: (method,url,headers,body,timeout,limit,done,w) => globalThis.FluxMobileTransport.request(method,url,headers,body,timeout,limit,(status,text)=>done(status)(text)(w))"
prim__request : String -> String -> String -> String -> Int -> Int ->
                (Int -> String -> PrimIO ()) -> PrimIO AnyPtr

%foreign "browser:lambda: handle => { handle.cancel(); }"
prim__cancel : AnyPtr -> PrimIO ()

transport : FetchOptions -> Transport
transport options request result = CancellableTask $ \send => do
  let headers = encode (JObject (map (\(key,value) => (key, JString value)) request.headers))
      complete : Int -> String -> PrimIO ()
      complete status body = toPrim $ send $ result $
        if status == -2 then Left Timeout
        else if status == -3 then Left (ResponseTooLarge options.maxResponseBytes)
        else if status < 0 then Left (NetworkError "Mobile RPC unavailable; no request has been retried")
        else if status >= 200 && status < 300 then Right (MkResponse status [] body)
        else Left (BadStatus status body)
  handle <- primIO (prim__request (methodStr request.method) request.url headers
    (fromMaybe "" request.body) (cast options.timeoutMs) (cast options.maxResponseBytes) complete)
  pure (primIO (prim__cancel handle))

export
mobileClient : FetchOptions -> IO (Either String Client)
mobileClient options = do
  origin <- primIO prim__origin
  ready <- primIO prim__ready
  if origin == "" || not ready then pure (Left "Mobile API is not configured. Build with a format-2 HTTPS API origin.")
    else if options.timeoutMs == 0 || options.timeoutMs > 120000 || options.maxResponseBytes == 0 || options.maxResponseBytes > 10485760
      then pure (Left "Invalid mobile request limits.")
      else pure (Right (MkClient origin (transport options)))
