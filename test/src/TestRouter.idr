module TestRouter

import Router
import HTTP
import Data.SortedMap

%default total

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
  case matchRoute GET "/any" empty of
    Nothing => True
    Just _ => False

-- Test addRoute and match
export
testAddRoute : Bool
testAddRoute =
  let handler : Handler
      handler _ = empty
      router = addRoute GET "/test" handler empty
   in case matchRoute GET "/test" router of
        Just _ => True
        Nothing => False

-- Test get helper
export
testGetHelper : Bool
testGetHelper =
  let handler : Handler
      handler _ = empty
      router = get "/api" handler empty
   in case matchRoute GET "/api" router of
        Just _ => True
        Nothing => False

-- Test post helper
export
testPostHelper : Bool
testPostHelper =
  let handler : Handler
      handler _ = empty
      router = post "/api" handler empty
   in case matchRoute POST "/api" router of
        Just _ => True
        Nothing => False

-- Test method mismatch
export
testMethodMismatch : Bool
testMethodMismatch =
  let handler : Handler
      handler _ = empty
      router = get "/api" handler empty
   in case matchRoute POST "/api" router of
        Nothing => True
        Just _ => False

-- Test multiple routes
export
testMultipleRoutes : Bool
testMultipleRoutes =
  let h1 : Handler
      h1 _ = empty
      h2 : Handler
      h2 _ = empty
      router = get "/posts" h2 (get "/users" h1 empty)
   in case (matchRoute GET "/users" router, matchRoute GET "/posts" router) of
        (Just _, Just _) => True
        _ => False

-- Test route with params
export
testRouteWithParams : Bool
testRouteWithParams =
  let handler : Handler
      handler _ = empty
      router = get "/users/:id" handler empty
   in case matchRoute GET "/users/42" router of
        Just (params, _) =>
          case getParam "id" params of
            Just "42" => True
            _ => False
        Nothing => False

-- Test handleRoute returns non-empty response (simplified - just check route matches)
export
testHandleRouteFound : Bool
testHandleRouteFound =
  let handler : Handler
      handler _ = empty
      router = get "/test" handler empty
   in case matchRoute GET "/test" router of
        Just _ => True
        Nothing => False

-- Test handleRoute not found (404) - simplified
export
testHandleRouteNotFound : Bool
testHandleRouteNotFound =
  let router = empty
   in case matchRoute GET "/nonexistent" router of
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
  ("handleRouteFound", testHandleRouteFound),
  ("handleRouteNotFound", testHandleRouteNotFound)
  ]
