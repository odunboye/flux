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

-- Test empty router
export
testEmptyRouter : Bool
testEmptyRouter =
  case matchRoute GET "/any" (the (Router Nat) empty) of
    Nothing => True
    Just _ => False

-- Test addRoute and match
export
testAddRoute : Bool
testAddRoute =
  let router = addRoute GET "/test" dummy empty
   in case matchRoute GET "/test" router of
        Just _ => True
        Nothing => False

-- Test get helper
export
testGetHelper : Bool
testGetHelper =
  let router = get "/api" dummy empty
   in case matchRoute GET "/api" router of
        Just _ => True
        Nothing => False

-- Test post helper
export
testPostHelper : Bool
testPostHelper =
  let router = post "/api" dummy empty
   in case matchRoute POST "/api" router of
        Just _ => True
        Nothing => False

-- Test method mismatch
export
testMethodMismatch : Bool
testMethodMismatch =
  let router = get "/api" dummy empty
   in case matchRoute POST "/api" router of
        Nothing => True
        Just _ => False

-- Test multiple routes
export
testMultipleRoutes : Bool
testMultipleRoutes =
  let router = get "/posts" dummy (get "/users" dummy empty)
   in case (matchRoute GET "/users" router, matchRoute GET "/posts" router) of
        (Just _, Just _) => True
        _ => False

-- Test route with params
export
testRouteWithParams : Bool
testRouteWithParams =
  let router = get "/users/:id" dummy empty
   in case matchRoute GET "/users/42" router of
        Just (params, _) =>
          case getParam "id" params of
            Just "42" => True
            _ => False
        Nothing => False

-- Test that routes match in declaration order (first added, first tried)
export
testDeclarationOrder : Bool
testDeclarationOrder =
  let router = get "/users/:id" 1 (get "/users/me" 2 empty)
   in case matchRoute GET "/users/me" router of
        Just (_, 2) => True
        _ => False

-- Test route not found (404 territory)
export
testRouteNotFound : Bool
testRouteNotFound =
  case matchRoute GET "/nonexistent" (the (Router Nat) empty) of
    Nothing => True
    Just _ => False

-- Run all router tests
export
runAllTests : List (String, Bool)
runAllTests = [
  ("parsePattern", testParsePattern),
  ("matchPathLiteral", testMatchPathLiteral),
  ("matchPathParams", testMatchPathParams),
  ("matchPathMismatch", testMatchPathMismatch),
  ("emptyRouter", testEmptyRouter),
  ("addRoute", testAddRoute),
  ("getHelper", testGetHelper),
  ("postHelper", testPostHelper),
  ("methodMismatch", testMethodMismatch),
  ("multipleRoutes", testMultipleRoutes),
  ("routeWithParams", testRouteWithParams),
  ("declarationOrder", testDeclarationOrder),
  ("routeNotFound", testRouteNotFound)
  ]
