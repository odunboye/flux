module TestRouter

import Flux.Core.Router
import Flux.Core.HTTP
import Data.SortedMap

%default total

-- A dummy handler payload; `Router`/`matchRoute` are generic over it, so a
-- plain `Nat` is enough to exercise routing without touching `Handler`.
dummy : Nat
dummy = 0

-- Test parsePattern returns non-empty results
export
testParsePattern : Bool
testParsePattern =
  let p1 = parsePattern "/users/:id"
      p2 = parsePattern "/api/posts"
   in length p1 > 0 && length p2 > 0

-- Test matchPath with literal segments
export
testMatchPathLiteral : Bool
testMatchPathLiteral =
  let pattern = parsePattern "/api/users"
   in case matchPath pattern "/api/users" of
        Just _ => True
        Nothing => False

-- Test matchPath with parameters
export
testMatchPathParams : Bool
testMatchPathParams =
  let pattern = parsePattern "/users/:id"
   in case matchPath pattern "/users/123" of
        Just params =>
          case getParam "id" params of
            Just "123" => True
            _ => False
        Nothing => False

-- Test matchPath mismatch
export
testMatchPathMismatch : Bool
testMatchPathMismatch =
  let pattern = parsePattern "/users/:id"
   in case matchPath pattern "/posts/123" of
        Nothing => True
        Just _ => False

-- Test matchPath with a splat segment consuming multiple remaining segments
export
testMatchPathSplat : Bool
testMatchPathSplat =
  let pattern = parsePattern "/static/*path"
   in case matchPath pattern "/static/js/app.js" of
        Just params =>
          case getParam "path" params of
            Just "js/app.js" => True
            _ => False
        Nothing => False

-- A path param is percent-decoded before being bound - a raw "%20" in
-- the request path becomes a real space in getParam's result, not the
-- literal three-character escape.
export
testMatchPathParamPercentDecoded : Bool
testMatchPathParamPercentDecoded =
  let pattern = parsePattern "/users/:name"
   in case matchPath pattern "/users/John%20Doe" of
        Just params =>
          case getParam "name" params of
            Just "John Doe" => True
            _ => False
        Nothing => False

-- A Literal pattern segment matches an encoded request segment that
-- decodes to the same text - decoding happens before either kind of
-- segment is compared, not just for :params.
export
testMatchPathLiteralPercentDecoded : Bool
testMatchPathLiteralPercentDecoded =
  let pattern = parsePattern "/api/users"
   in case matchPath pattern "/api/user%73" of
        Just _  => True
        Nothing => False

-- A malformed escape (not two hex digits after "%") is left as-is
-- rather than rejected.
export
testMatchPathMalformedEscapeIsLiteral : Bool
testMatchPathMalformedEscapeIsLiteral =
  let pattern = parsePattern "/users/:name"
   in case matchPath pattern "/users/100%" of
        Just params =>
          case getParam "name" params of
            Just "100%" => True
            _ => False
        Nothing => False

-- A splat also matches when there's nothing left to consume
export
testMatchPathSplatEmpty : Bool
testMatchPathSplatEmpty =
  let pattern = parsePattern "/static/*path"
   in case matchPath pattern "/static" of
        Just params =>
          case getParam "path" params of
            Just "" => True
            _ => False
        Nothing => False

-- Test empty router
export
testEmptyRouter : Bool
testEmptyRouter =
  case matchRoute GET "/any" (the (Router Nat) empty) of
    NoMatch => True
    _ => False

-- Test addRoute and match
export
testAddRoute : Bool
testAddRoute =
  let router = addRoute GET "/test" dummy empty
   in case matchRoute GET "/test" router of
        Matched _ _ => True
        _ => False

-- Test get helper
export
testGetHelper : Bool
testGetHelper =
  let router = get "/api" dummy empty
   in case matchRoute GET "/api" router of
        Matched _ _ => True
        _ => False

-- Test post helper
export
testPostHelper : Bool
testPostHelper =
  let router = post "/api" dummy empty
   in case matchRoute POST "/api" router of
        Matched _ _ => True
        _ => False

-- Test put/delete/patch/options_ helpers
export
testPutHelper : Bool
testPutHelper =
  case matchRoute PUT "/api" (put "/api" dummy empty) of
    Matched _ _ => True
    _ => False

export
testDeleteHelper : Bool
testDeleteHelper =
  case matchRoute DELETE "/api" (delete "/api" dummy empty) of
    Matched _ _ => True
    _ => False

export
testPatchHelper : Bool
testPatchHelper =
  case matchRoute PATCH "/api" (patch "/api" dummy empty) of
    Matched _ _ => True
    _ => False

export
testOptionsHelper : Bool
testOptionsHelper =
  case matchRoute OPTIONS "/api" (options_ "/api" dummy empty) of
    Matched _ _ => True
    _ => False

-- Test a genuine 405: path matches, method doesn't - the wrong-method
-- route's method should come back so a 405 can carry an Allow header.
-- `Allow` should list HEAD alongside GET here too, even though this is
-- a POST request rather than a HEAD one - HEAD works wherever GET does
-- (see `addImplicitHead`), so an accurate `Allow` must say so regardless
-- of which method the caller actually tried.
export
testMethodMismatchIs405 : Bool
testMethodMismatchIs405 =
  let router = get "/api" dummy empty
   in case matchRoute POST "/api" router of
        WrongMethod [GET, HEAD] => True
        _ => False

-- Test multiple routes
export
testMultipleRoutes : Bool
testMultipleRoutes =
  let router = get "/posts" dummy (get "/users" dummy empty)
   in case (matchRoute GET "/users" router, matchRoute GET "/posts" router) of
        (Matched _ _, Matched _ _) => True
        _ => False

-- Test route with params
export
testRouteWithParams : Bool
testRouteWithParams =
  let router = get "/users/:id" dummy empty
   in case matchRoute GET "/users/42" router of
        Matched params _ =>
          case getParam "id" params of
            Just "42" => True
            _ => False
        _ => False

-- Test that routes match in declaration order (first added, first tried)
export
testDeclarationOrder : Bool
testDeclarationOrder =
  let router = get "/users/:id" 1 (get "/users/me" 2 empty)
   in case matchRoute GET "/users/me" router of
        Matched _ 2 => True
        _ => False

-- Test route not found (no route registered for this path at all)
export
testRouteNotFound : Bool
testRouteNotFound =
  case matchRoute GET "/nonexistent" (the (Router Nat) empty) of
    NoMatch => True
    _ => False

--------------------------------------------------------------------------------
-- HEAD falls back to a matching GET route (RFC 9110 §9.3.2)
--------------------------------------------------------------------------------

-- A route registered only via `get` still answers a HEAD request, via the
-- GET fallback in `matchRoute`.
export
testHeadFallsBackToGet : Bool
testHeadFallsBackToGet =
  let router = get "/api" dummy empty
   in case matchRoute HEAD "/api" router of
        Matched _ _ => True
        _ => False

-- An explicit `head_` route always wins over the GET fallback, even when
-- both are registered for the same path - confirmed by checking which
-- handler value comes back, not just that *a* match happened.
export
testExplicitHeadOverridesGetFallback : Bool
testExplicitHeadOverridesGetFallback =
  let router = head_ "/api" 99 (get "/api" dummy empty)
   in case matchRoute HEAD "/api" router of
        Matched _ 99 => True
        _ => False

-- A path with only a POST route still 405s a HEAD request - the fallback
-- is specifically to GET, not to "any other method".
export
testHeadFallbackDoesNotApplyToPost : Bool
testHeadFallbackDoesNotApplyToPost =
  let router = post "/api" dummy empty
   in case matchRoute HEAD "/api" router of
        WrongMethod [POST] => True
        _ => False

-- `Allow` includes HEAD wherever GET is allowed, for a HEAD request's own
-- 405 too (path exists, but only for an unrelated method, so the GET
-- fallback doesn't apply - `addImplicitHead` should still not fire here,
-- since GET itself was never actually allowed on this path).
export
testHeadWrongMethodDoesNotGainHeadWithoutGet : Bool
testHeadWrongMethodDoesNotGainHeadWithoutGet =
  let router = post "/api" dummy empty
   in case matchRoute PUT "/api" router of
        WrongMethod [POST] => True
        _ => False

-- `Allow` includes HEAD wherever GET is allowed, for a non-HEAD
-- wrong-method request too (not just when the request itself was HEAD).
export
testAllowIncludesHeadForNonHeadRequest : Bool
testAllowIncludesHeadForNonHeadRequest =
  let router = get "/api" dummy empty
   in case matchRoute DELETE "/api" router of
        WrongMethod [GET, HEAD] => True
        _ => False

-- Run all router tests
export
runAllTests : List (String, Bool)
runAllTests = [
  ("parsePattern", testParsePattern),
  ("matchPathLiteral", testMatchPathLiteral),
  ("matchPathParams", testMatchPathParams),
  ("matchPathMismatch", testMatchPathMismatch),
  ("matchPathSplat", testMatchPathSplat),
  ("matchPathSplatEmpty", testMatchPathSplatEmpty),
  ("matchPathParamPercentDecoded", testMatchPathParamPercentDecoded),
  ("matchPathLiteralPercentDecoded", testMatchPathLiteralPercentDecoded),
  ("matchPathMalformedEscapeIsLiteral", testMatchPathMalformedEscapeIsLiteral),
  ("emptyRouter", testEmptyRouter),
  ("addRoute", testAddRoute),
  ("getHelper", testGetHelper),
  ("postHelper", testPostHelper),
  ("putHelper", testPutHelper),
  ("deleteHelper", testDeleteHelper),
  ("patchHelper", testPatchHelper),
  ("optionsHelper", testOptionsHelper),
  ("methodMismatchIs405", testMethodMismatchIs405),
  ("multipleRoutes", testMultipleRoutes),
  ("routeWithParams", testRouteWithParams),
  ("declarationOrder", testDeclarationOrder),
  ("routeNotFound", testRouteNotFound),
  ("headFallsBackToGet", testHeadFallsBackToGet),
  ("explicitHeadOverridesGetFallback", testExplicitHeadOverridesGetFallback),
  ("headFallbackDoesNotApplyToPost", testHeadFallbackDoesNotApplyToPost),
  ("headWrongMethodDoesNotGainHeadWithoutGet", testHeadWrongMethodDoesNotGainHeadWithoutGet),
  ("allowIncludesHeadForNonHeadRequest", testAllowIncludesHeadForNonHeadRequest)
  ]
