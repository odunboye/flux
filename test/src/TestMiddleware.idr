module TestMiddleware

import Middleware
import Router

%default total
%language ElabReflection

-- Test emptyApp
export
testEmptyApp : Bool
testEmptyApp =
  case emptyApp of
    MkApp r _ =>
      case matchRoute GET "/any" r of
        Nothing => True
        Just _ => False

-- Test use middleware
export
testUse : Bool
testUse =
  let mw : Middleware
      mw = \c => c
      app0 = emptyApp
      app1 = use mw app0
   in case app1 of
        MkApp _ mid => length mid == 1

-- Test withRoutes
export partial
testWithRoutes : Bool
testWithRoutes =
  let handler : Handler
      handler = \_ => empty
      router = get "/test" handler empty
      app0 = emptyApp
      app1 = withRoutes router app0
   in case app1 of
        MkApp r _ =>
          case matchRoute GET "/test" r of
            Just _ => True
            Nothing => False

-- Run all middleware tests
export partial
runAllTests : List (String, Bool)
runAllTests = [
  ("emptyApp", testEmptyApp),
  ("use", testUse),
  ("withRoutes", testWithRoutes)
  ]
