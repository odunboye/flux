module TestRpcCors

import Flux.Middleware.RpcCors
import Data.IORef
import Data.SortedMap
import Data.String

%default covering

runContext : AppProg Context -> IO (Either Nat Context)
runContext action = do
  result <- newIORef (the (Either Nat Context) (Left 0))
  runProg $ handleErrors
    (\case
      Here _ => liftIO (writeIORef result (Left 500))
      There (Here error) => liftIO (writeIORef result (Left error.status)))
    (foreach (\ctx => liftIO (writeIORef result (Right ctx))) (eval action))
  readIORef result

request : Method -> List (String, String) -> Context
request method headers = emptyContext (R method "/rpc/v1/auth/login" empty V11 (fromList headers) 0 Nothing (pure (pure ())))

origins : List String
origins = ["capacitor://localhost", "https://localhost", "https://web.example.com"]

export
runAllTests : IO (List (String, Bool))
runAllTests = do
  let valid = all validRpcOrigin origins && validRpcOrigin "https://127.0.0.1:8443"
      invalid = all (not . validRpcOrigin) ["*", "null", "", "http://localhost", "https://user@host", "https://host/path", "https://host:0", "https://host:443", "https://host?query", "https://host\r\nX:1"]
      options = request OPTIONS [("origin", "capacitor://localhost"), ("access-control-request-method", "POST"),
                                 ("access-control-request-headers", "authorization, content-type")]
  preflight <- runContext (rpcOriginGuard origins options >>= rpcCorsHeaders origins . setHeader "Vary" "Accept-Encoding" . setStatus 405)
  let preflightOK = case preflight of
        Right ctx => ctx.statusCode == 204 && lookup "Access-Control-Allow-Origin" ctx.respHeaders == Just "capacitor://localhost" &&
          lookup "Access-Control-Allow-Credentials" ctx.respHeaders == Nothing &&
          lookup "Access-Control-Allow-Methods" ctx.respHeaders == Just "POST" &&
          maybe False (isInfixOf "Accept-Encoding") (lookup "Vary" ctx.respHeaders)
        _ => False
  dispatched <- newIORef False
  denied <- runContext $ do
    ctx <- rpcOriginGuard origins (request POST [("origin", "https://evil.example")])
    liftIO (writeIORef dispatched True)
    pure ctx
  ran <- readIORef dispatched
  let deniedOK = not ran && case denied of Left 403 => True; _ => False
  badMethod <- runContext (rpcOriginGuard origins (request OPTIONS [("origin", "https://localhost"), ("access-control-request-method", "DELETE")]))
  badHeader <- runContext (rpcOriginGuard origins (request OPTIONS [("origin", "https://localhost"), ("access-control-request-method", "POST"), ("access-control-request-headers", "x-debug")]))
  readable <- runContext (rpcCorsHeaders origins (setStatus 401 (request POST [("origin", "https://localhost")])))
  let errorOK = case readable of
        Right ctx => ctx.statusCode == 401 && lookup "Access-Control-Allow-Origin" ctx.respHeaders == Just "https://localhost" && lookup "Cache-Control" ctx.respHeaders == Just "no-store"
        _ => False
  disabled <- runContext (rpcOriginGuard [] (request POST [("origin", "http://127.0.0.1:8000")]) >>= rpcCorsHeaders [])
  let disabledOK = case disabled of
        Right ctx => lookup "Access-Control-Allow-Origin" ctx.respHeaders == Nothing
        _ => False
  pure [("Exact origin configuration", valid && invalid), ("Owned POST preflight without credentials", preflightOK),
        ("Unapproved origin blocked before dispatch", deniedOK),
        ("Unsupported preflight method", case badMethod of Left 403 => True; _ => False),
        ("Unsupported preflight headers", case badHeader of Left 403 => True; _ => False),
        ("401 remains readable to allowed clients", errorOK), ("Unset policy preserves web behavior", disabledOK)]
