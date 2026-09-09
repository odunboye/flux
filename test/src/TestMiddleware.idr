module TestMiddleware

import Flux.Core.Middleware
import Flux.Core.Router
import Flux.Core.HTTP
import Data.IORef
import Data.String
import System

%default covering

export
testEmptyApp : Bool
testEmptyApp =
  case emptyApp of
    MkApp r _ _ _ _ =>
      case matchRoute GET "/any" r of
        NoMatch => True
        _ => False

-- `use` adds to the before-chain
export
testUse : Bool
testUse =
  let mw : Middleware
      mw = pure
      app1 = use mw emptyApp
   in case app1 of
        MkApp _ before _ _ _ => length before == 1

-- `useAfter` adds to the after-chain, independently of `use`
export
testUseAfter : Bool
testUseAfter =
  let mw : Middleware
      mw = pure
      app1 = useAfter mw emptyApp
   in case app1 of
        MkApp _ before after _ _ => length before == 0 && length after == 1

-- `useAlways` adds to the always-chain, independently of `use`/`useAfter`
export
testUseAlways : Bool
testUseAlways =
  let mw : Middleware
      mw = pure
      app1 = useAlways mw emptyApp
   in case app1 of
        MkApp _ before after always _ => length before == 0 && length after == 0 && length always == 1

export
testWithRoutes : Bool
testWithRoutes =
  let handler : Handler
      handler = pure
      router = get "/test" handler empty
      app1 = withRoutes router emptyApp
   in case app1 of
        MkApp r _ _ _ _ =>
          case matchRoute GET "/test" r of
            Matched _ _ => True
            _           => False

--------------------------------------------------------------------------------
-- End-to-end: does runApp actually catch failures and render a response,
-- rather than letting them propagate and silently drop the connection?
--------------------------------------------------------------------------------

-- A bare request with no body, just enough to drive runApp end-to-end.
dummyRequest : Request
dummyRequest = R GET "/" empty V11 empty 0 Nothing (pure (pure ()))

-- A "\r\n" embedded in a header value would otherwise inject an entire
-- extra header line into the response - stripped rather than rejected,
-- so setHeader stays a plain, non-fallible function.
export
testSetHeaderStripsCRLF : Bool
testSetHeaderStripsCRLF =
  let ctx = setHeader "X-Custom" "value\r\nX-Injected: evil" (emptyContext dummyRequest)
   in lookup "X-Custom" ctx.respHeaders == Just "valueX-Injected: evil"

-- Runs an HTTPPull for real, via the async runtime, concatenating
-- everything it emits and discarding its result (a BodyOutcome, for
-- runApp's output specifically - not needed to check what got emitted) -
-- needed because runApp's error-catching (and, once streaming responses
-- are involved, its chunking) is a runtime behavior, not something
-- visible from its type alone.
runOnce : HTTPPull ByteString r -> IO ByteString
runOnce stream = do
  ref <- newIORef []
  runProg $
    handleErrors
      (\case
        Here e         => liftIO (putStrLn "runOnce: unexpected Errno: \{e}")
        There (Here e) => liftIO (putStrLn "runOnce: unexpected HTTPErr: \{e}"))
      (ignore (foreach (\v => liftIO (modifyIORef ref (v ::))) stream))
  chunks <- readIORef ref
  pure (fastConcat (reverse chunks))

export
testRunAppCatchesAppError : IO Bool
testRunAppCatchesAppError = do
  let failingHandler : Handler
      failingHandler _ = throw (MkAppError 404 "not found")
      myApp = withRoutes (get "/" failingHandler empty) emptyApp
  resp <- runOnce (runApp myApp dummyRequest)
  let respStr = toString resp
  pure $ isInfixOf "404" respStr && isInfixOf "not found" respStr

export
testRunAppCatchesErrno : IO Bool
testRunAppCatchesErrno = do
  let failingHandler : Handler
      failingHandler _ = throw EPERM
      myApp = withRoutes (get "/" failingHandler empty) emptyApp
  resp <- runOnce (runApp myApp dummyRequest)
  let respStr = toString resp
  pure $ isInfixOf "500" respStr

export
testWithErrorRenderer : IO Bool
testWithErrorRenderer = do
  let failingHandler : Handler
      failingHandler _ = throw (MkAppError 418 "teapot")
      myApp = withErrorRenderer (\err => setStatus err.status . sendText ("custom: " ++ err.message)) $
                withRoutes (get "/" failingHandler empty) emptyApp
  resp <- runOnce (runApp myApp dummyRequest)
  let respStr = toString resp
  pure $ isInfixOf "418" respStr && isInfixOf "custom: teapot" respStr

--------------------------------------------------------------------------------
-- always: registered hooks run on both the success and error-render paths
--------------------------------------------------------------------------------

markAlways : Middleware
markAlways = pure . setHeader "X-Always" "yes"

export
testAlwaysRunsOnSuccess : IO Bool
testAlwaysRunsOnSuccess = do
  let okHandler : Handler
      okHandler = pure . sendText "ok"
      myApp = useAlways markAlways $ withRoutes (get "/" okHandler empty) emptyApp
  resp <- runOnce (runApp myApp dummyRequest)
  pure (isInfixOf "X-Always: yes" (toString resp))

-- The bug this exists to fix: before this, an always-hook (or an
-- ordinary before/after hook) never ran at all for a request that threw
-- - see App's doc comment.
export
testAlwaysRunsOnError : IO Bool
testAlwaysRunsOnError = do
  let failingHandler : Handler
      failingHandler _ = throw (MkAppError 404 "not found")
      myApp = useAlways markAlways $ withRoutes (get "/" failingHandler empty) emptyApp
  resp <- runOnce (runApp myApp dummyRequest)
  pure (isInfixOf "X-Always: yes" (toString resp))

-- Contrast case: an ordinary `after` hook still doesn't run on the error
-- path (unchanged behavior) - `always` is the escape hatch, not a
-- silent change to what `after` itself means.
export
testAfterStillSkippedOnError : IO Bool
testAfterStillSkippedOnError = do
  let failingHandler : Handler
      failingHandler _ = throw (MkAppError 404 "not found")
      myApp = useAfter markAlways $ withRoutes (get "/" failingHandler empty) emptyApp
  resp <- runOnce (runApp myApp dummyRequest)
  pure (not (isInfixOf "X-Always: yes" (toString resp)))

--------------------------------------------------------------------------------
-- render: HEAD/204/304 body suppression, no duplicate framing headers
--------------------------------------------------------------------------------

dummyHeadRequest : Request
dummyHeadRequest = R HEAD "/" empty V11 empty 0 Nothing (pure (pure ()))

-- Exercises render directly rather than through the router, to isolate
-- render's own body-suppression logic from routing (the router now
-- falls a HEAD request back to a matching `get` route - see
-- TestRouter.idr - but that's a separate concern from what render does
-- with the resulting HEAD-method context).
export
testRenderSuppressesBodyForHead : IO Bool
testRenderSuppressesBodyForHead = do
  let ctx = sendText "hello" (emptyContext dummyHeadRequest)
  resp <- runOnce (render False ctx)
  let respStr = toString resp
  -- Headers (including a real Content-Length) still describe what a GET
  -- would have sent - just no body bytes after them.
  pure $ isInfixOf "Content-Length: 5" respStr && not (isInfixOf "hello" respStr)

export
testRenderSuppressesBodyFor204 : IO Bool
testRenderSuppressesBodyFor204 = do
  let handler : Handler
      handler ctx = pure (setStatus 204 (sendText "hello" ctx))
      myApp = withRoutes (get "/" handler empty) emptyApp
  resp <- runOnce (runApp myApp dummyRequest)
  let respStr = toString resp
  pure $ not (isInfixOf "hello" respStr) && not (isInfixOf "Content-Length" respStr)

export
testRenderDoesNotDuplicateContentLength : IO Bool
testRenderDoesNotDuplicateContentLength = do
  let handler : Handler
      handler ctx = pure (setHeader "Content-Length" "999" (sendText "hi" ctx))
      myApp = withRoutes (get "/" handler empty) emptyApp
  resp <- runOnce (runApp myApp dummyRequest)
  let respStr = toString resp
  -- Exactly one Content-Length, and it's render's own correct value -
  -- never the caller-supplied one.
  pure $ isInfixOf "Content-Length: 2" respStr && not (isInfixOf "Content-Length: 999" respStr)

--------------------------------------------------------------------------------
-- readBody: a Handler reading Context.request.body via the router layer
--------------------------------------------------------------------------------

-- A synthetic HTTPBody emitting the given chunks, then resulting in an
-- empty continuation - enough to drive readBody without a real socket.
mkBody : List ByteString -> HTTPBody
mkBody []        = pure (pure ())
mkBody (c :: cs) = emit c >> mkBody cs

dummyRequestWithBody : List ByteString -> Request
dummyRequestWithBody chunks =
  R POST "/" empty V11 empty (sum (map length chunks)) Nothing (mkBody chunks)

-- Like runOnce, but also keeps runApp's BodyOutcome result instead of
-- discarding it - needed to check whether a connection was reported
-- ContinueWith (keep-alive) or CloseAfterResponse.
runAppOnce : HTTPPull ByteString BodyOutcome -> IO (ByteString, BodyOutcome)
runAppOnce stream = do
  ref    <- newIORef []
  outRef <- newIORef CloseAfterResponse
  runProg $
    handleErrors
      (\case
        Here e         => liftIO (putStrLn "runAppOnce: unexpected Errno: \{e}")
        There (Here e) => liftIO (putStrLn "runAppOnce: unexpected HTTPErr: \{e}"))
      (Prelude.do
        outcome <- foreach (\v => liftIO (modifyIORef ref (v ::))) stream
        liftIO (writeIORef outRef outcome))
  chunks  <- readIORef ref
  outcome <- readIORef outRef
  pure (fastConcat (reverse chunks), outcome)

isContinue : BodyOutcome -> Bool
isContinue (ContinueWith _) = True
isContinue CloseAfterResponse = False

export
testReadBodySuccess : IO Bool
testReadBodySuccess = do
  let req = dummyRequestWithBody [fromString "hello ", fromString "world"]
      handler : Handler
      handler ctx = do
        Right bytes <- readBody 1024 ctx
          | Left _ => pure (setStatus 500 (sendText "read failed" ctx))
        pure (sendText (toString bytes) ctx)
      myApp = withRoutes (post "/" handler empty) emptyApp
  (resp, outcome) <- runAppOnce (runApp myApp req)
  pure $ isInfixOf "hello world" (toString resp) && isContinue outcome

export
testReadBodyTooLargeClosesConnection : IO Bool
testReadBodyTooLargeClosesConnection = do
  let req = dummyRequestWithBody [fromString (pack (replicate 100 'x'))]
      handler : Handler
      handler ctx = do
        result <- readBody 10 ctx
        case result of
          Left BodyTooLarge => pure (setStatus 413 (sendText "too large" ctx))
          Left _            => pure (setStatus 400 (sendText "bad" ctx))
          Right _           => pure (setStatus 200 (sendText "should not happen" ctx))
      myApp = withRoutes (post "/" handler empty) emptyApp
  (resp, outcome) <- runAppOnce (runApp myApp req)
  pure $ isInfixOf "413" (toString resp) && not (isContinue outcome)

-- The specific bug found and fixed while implementing this: runApp resets
-- to a *fresh* Context whenever anything throws, which would silently
-- lose an ordinary Context field recording "the body was read" - a
-- Handler that reads the body successfully and *then* throws for an
-- unrelated reason must still report ContinueWith, not lose it to that
-- reset. See readBody's doc comment.
export
testReadBodySurvivesLaterThrow : IO Bool
testReadBodySurvivesLaterThrow = do
  let req = dummyRequestWithBody [fromString "ok"]
      handler : Handler
      handler ctx = do
        Right _ <- readBody 1024 ctx
          | Left _ => pure (setStatus 500 (sendText "read failed" ctx))
        throw (MkAppError 400 "unrelated failure after reading body")
      myApp = withRoutes (post "/" handler empty) emptyApp
  (resp, outcome) <- runAppOnce (runApp myApp req)
  pure $ isInfixOf "400" (toString resp) && isContinue outcome

-- Baseline: a Handler that never touches the body at all still keeps the
-- connection alive (runApp drains it itself) - the ordinary, most common
-- case, unaffected by any of the above.
export
testUntouchedBodyKeepsConnectionAlive : IO Bool
testUntouchedBodyKeepsConnectionAlive = do
  let req = dummyRequestWithBody [fromString "ignored"]
      handler : Handler
      handler ctx = pure (sendText "ok" ctx)
      myApp = withRoutes (post "/" handler empty) emptyApp
  (_, outcome) <- runAppOnce (runApp myApp req)
  pure (isContinue outcome)

---------------------------------------------------------------------------------
-- Connection header / keep-alive: the response's own Connection header
-- must reflect the *real* close decision - both the client's own
-- Connection header (shouldKeepAlive) and an unrelated forced close from
-- a readBody failure (BodyReadState == Unsafe) elsewhere in the same
-- request, per HTTP.shouldKeepAlive's doc comment and runApp's willClose
-- computation. This is the property most likely to silently regress,
-- since it depends on two independent inputs agreeing - see the plan
-- this was implemented from.
---------------------------------------------------------------------------------

okHandler : Handler
okHandler = pure . sendText "ok"

-- HTTP/1.1 defaults to persistent: no Connection header in, none out.
export
testResponseOmitsConnectionCloseByDefaultOnV11 : IO Bool
testResponseOmitsConnectionCloseByDefaultOnV11 = do
  let req = R GET "/" empty V11 empty 0 Nothing (pure (pure ()))
      myApp = withRoutes (get "/" okHandler empty) emptyApp
  (resp, _) <- runAppOnce (runApp myApp req)
  pure (not (isInfixOf "Connection: close" (toString resp)))

-- A client-sent "Connection: close" on HTTP/1.1 must be echoed back so
-- the client knows not to expect another response on this connection.
export
testResponseCarriesConnectionCloseWhenClientAsksOnV11 : IO Bool
testResponseCarriesConnectionCloseWhenClientAsksOnV11 = do
  let req = R GET "/" empty V11 (fromList [("connection", "close")]) 0 Nothing (pure (pure ()))
      myApp = withRoutes (get "/" okHandler empty) emptyApp
  (resp, _) <- runAppOnce (runApp myApp req)
  pure (isInfixOf "Connection: close" (toString resp))

-- HTTP/1.0 defaults to closing (no Connection header at all): the
-- response should say so explicitly.
export
testResponseCarriesConnectionCloseByDefaultOnV10 : IO Bool
testResponseCarriesConnectionCloseByDefaultOnV10 = do
  let req = R GET "/" empty V10 empty 0 Nothing (pure (pure ()))
      myApp = withRoutes (get "/" okHandler empty) emptyApp
  (resp, _) <- runAppOnce (runApp myApp req)
  pure (isInfixOf "Connection: close" (toString resp))

-- HTTP/1.0 with an explicit "Connection: keep-alive" stays open.
export
testResponseOmitsConnectionCloseWhenV10AsksKeepAlive : IO Bool
testResponseOmitsConnectionCloseWhenV10AsksKeepAlive = do
  let req = R GET "/" empty V10 (fromList [("connection", "keep-alive")]) 0 Nothing (pure (pure ()))
      myApp = withRoutes (get "/" okHandler empty) emptyApp
  (resp, _) <- runAppOnce (runApp myApp req)
  pure (not (isInfixOf "Connection: close" (toString resp)))

-- The critical, regression-prone case: a readBody failure forces the
-- connection closed even though the client explicitly asked to keep it
-- alive on HTTP/1.1 - render has no visibility into the body-read
-- outcome on its own, so this only holds if runApp actually threads
-- `isUnsafe` into `willClose` alongside `shouldKeepAlive req` (see
-- runApp's own doc comment on this).
export
testReadBodyFailureForcesConnectionCloseDespiteKeepAliveRequest : IO Bool
testReadBodyFailureForcesConnectionCloseDespiteKeepAliveRequest = do
  let chunks = [fromString (pack (replicate 100 'x'))]
      req = R POST "/" empty V11 (fromList [("connection", "keep-alive")])
              (sum (map length chunks)) Nothing (mkBody chunks)
      handler : Handler
      handler ctx = do
        result <- readBody 10 ctx
        case result of
          Left BodyTooLarge => pure (setStatus 413 (sendText "too large" ctx))
          Left _            => pure (setStatus 400 (sendText "bad" ctx))
          Right _           => pure (setStatus 200 (sendText "should not happen" ctx))
      myApp = withRoutes (post "/" handler empty) emptyApp
  (resp, outcome) <- runAppOnce (runApp myApp req)
  pure $ isInfixOf "Connection: close" (toString resp) && not (isContinue outcome)

-- Run all middleware tests (mixing pure and IO-backed cases, since the
-- end-to-end runApp tests are inherently effectful)
export
runAllTests : IO (List (String, Bool))
runAllTests = do
  appErrorResult    <- testRunAppCatchesAppError
  errnoResult       <- testRunAppCatchesErrno
  errorRendererResult <- testWithErrorRenderer
  alwaysOnSuccessResult <- testAlwaysRunsOnSuccess
  alwaysOnErrorResult   <- testAlwaysRunsOnError
  afterSkippedOnErrorResult <- testAfterStillSkippedOnError
  renderHeadResult      <- testRenderSuppressesBodyForHead
  render204Result       <- testRenderSuppressesBodyFor204
  renderNoDupCLResult   <- testRenderDoesNotDuplicateContentLength
  readBodySuccessResult      <- testReadBodySuccess
  readBodyTooLargeResult     <- testReadBodyTooLargeClosesConnection
  readBodySurvivesThrowResult <- testReadBodySurvivesLaterThrow
  untouchedBodyResult        <- testUntouchedBodyKeepsConnectionAlive
  connOmitsDefaultV11Result  <- testResponseOmitsConnectionCloseByDefaultOnV11
  connClosesOnClientAskV11Result <- testResponseCarriesConnectionCloseWhenClientAsksOnV11
  connClosesDefaultV10Result <- testResponseCarriesConnectionCloseByDefaultOnV10
  connOmitsV10KeepAliveResult <- testResponseOmitsConnectionCloseWhenV10AsksKeepAlive
  connForcedByReadBodyFailureResult <- testReadBodyFailureForcesConnectionCloseDespiteKeepAliveRequest
  pure
    [ ("setHeaderStripsCRLF", testSetHeaderStripsCRLF)
    , ("emptyApp", testEmptyApp)
    , ("use", testUse)
    , ("useAfter", testUseAfter)
    , ("useAlways", testUseAlways)
    , ("withRoutes", testWithRoutes)
    , ("runAppCatchesAppError", appErrorResult)
    , ("runAppCatchesErrno", errnoResult)
    , ("withErrorRenderer", errorRendererResult)
    , ("alwaysRunsOnSuccess", alwaysOnSuccessResult)
    , ("alwaysRunsOnError", alwaysOnErrorResult)
    , ("afterStillSkippedOnError", afterSkippedOnErrorResult)
    , ("renderSuppressesBodyForHead", renderHeadResult)
    , ("renderSuppressesBodyFor204", render204Result)
    , ("renderDoesNotDuplicateContentLength", renderNoDupCLResult)
    , ("readBodySuccess", readBodySuccessResult)
    , ("readBodyTooLargeClosesConnection", readBodyTooLargeResult)
    , ("readBodySurvivesLaterThrow", readBodySurvivesThrowResult)
    , ("untouchedBodyKeepsConnectionAlive", untouchedBodyResult)
    , ("responseOmitsConnectionCloseByDefaultOnV11", connOmitsDefaultV11Result)
    , ("responseCarriesConnectionCloseWhenClientAsksOnV11", connClosesOnClientAskV11Result)
    , ("responseCarriesConnectionCloseByDefaultOnV10", connClosesDefaultV10Result)
    , ("responseOmitsConnectionCloseWhenV10AsksKeepAlive", connOmitsV10KeepAliveResult)
    , ("readBodyFailureForcesConnectionCloseDespiteKeepAliveRequest", connForcedByReadBodyFailureResult)
    ]
