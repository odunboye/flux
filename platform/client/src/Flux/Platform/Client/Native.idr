module Flux.Platform.Client.Native

import public Flux.Platform.Client
import Data.String
import Data.List
import Data.Maybe

%default covering

%foreign "C:flux_client_new,libflux_client_http"
newRequest : String -> String -> String -> String -> Int -> String -> PrimIO AnyPtr
%foreign "C__collect_safe:flux_client_perform,libflux_client_http"
perform : AnyPtr -> PrimIO Int
%foreign "C:flux_client_status,libflux_client_http"
status : AnyPtr -> PrimIO Int
%foreign "C:flux_client_body,libflux_client_http"
body : AnyPtr -> PrimIO String
%foreign "C:flux_client_free,libflux_client_http"
freeRequest : AnyPtr -> PrimIO ()

method : Method -> String
method GET = "GET"
method POST = "POST"
method PUT = "PUT"
method PATCH = "PATCH"
method DELETE = "DELETE"
method HEAD = "HEAD"
method OPTIONS = "OPTIONS"

safeHeader : (String, String) -> Bool
safeHeader (name,value) = not (null (unpack name)) &&
  all (\c => (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
             (c >= '0' && c <= '9') || c == '-') (unpack name) &&
  all (\c => ord c >= 32 && ord c /= 127) (unpack value)

run : Maybe String -> HttpRequest -> IO (Either HttpError HttpResponse)
run ca req = do
  let auth = filter (\(k,_) => toLower k == "authorization") req.headers
  if length req.headers > 32 || length auth > 1 || not (all safeHeader req.headers) ||
     elem '\0' (unpack req.url) || maybe False (\s => elem '\0' (unpack s)) req.body ||
     maybe False (\s => s == "" || elem '\0' (unpack s)) ca
    then pure (Left (NetworkError "Invalid native request"))
    else do
      let headers = concat (map (\(k,v) => k ++ ": " ++ v ++ "\n") req.headers)
      p <- primIO (newRequest (method req.method) req.url headers (fromMaybe "" req.body)
                             (if isJust req.body then 1 else 0) (fromMaybe "" ca))
      if prim__nullAnyPtr p /= 0 then pure (Left (NetworkError "Native request allocation or size limit")) else do
        result <- primIO (perform p)
        if result /= 0
          then do
            primIO (freeRequest p)
            pure (Left (if result == -3 then Timeout else NetworkError "Native transport rejected or failed request"))
          else do
            code <- primIO (status p)
            value <- primIO (body p)
            primIO (freeRequest p)
            pure $ if code >= 200 && code < 300 then Right (MkResponse code [] value)
              else Left (BadStatus code value)

||| In-process libcurl: no shell, argv credentials or temporary body files.
||| Synchronous native Task with finite 5s connect / 30s total limits and a 64KiB
||| response cap. No redirects, ambient proxies, cookies or netrc. HTTPS required
||| except loopback development; peer identity verification cannot be disabled.
export
nativeClientWithCA : String -> Maybe String -> Client
nativeClientWithCA base ca = MkClient base (\req, done => Task (done <$> run ca req))

export
nativeClient : String -> Client
nativeClient base = nativeClientWithCA base Nothing
