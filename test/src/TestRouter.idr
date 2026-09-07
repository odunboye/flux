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
export
testMethodMismatchIs405 : Bool
testMethodMismatchIs405 =
  let router = get "/api" dummy empty
   in case matchRoute POST "/api" router of
        WrongMethod [GET] => True
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
  ("routeNotFound", testRouteNotFound)
  ]
