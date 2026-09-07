module TestMiddleware

import Flux.Core.Middleware
import Flux.Core.Router

%default total

export
testEmptyApp : Bool
testEmptyApp =
  case emptyApp of
    MkApp r _ _ =>
      case matchRoute GET "/any" r of
        Nothing => True
        Just _ => False

-- `use` adds to the before-chain
export
testUse : Bool
testUse =
  let mw : Middleware
      mw = pure
      app1 = use mw emptyApp
   in case app1 of
        MkApp _ before _ => length before == 1

-- `useAfter` adds to the after-chain, independently of `use`
export
testUseAfter : Bool
testUseAfter =
  let mw : Middleware
      mw = pure
      app1 = useAfter mw emptyApp
   in case app1 of
        MkApp _ before after => length before == 0 && length after == 1

export
testWithRoutes : Bool
testWithRoutes =
  let handler : Handler
      handler = pure
      router = get "/test" handler empty
      app1 = withRoutes router emptyApp
   in case app1 of
        MkApp r _ _ =>
          case matchRoute GET "/test" r of
            Just _ => True
            Nothing => False

-- Run all middleware tests
export
runAllTests : List (String, Bool)
runAllTests = [
  ("emptyApp", testEmptyApp),
  ("use", testUse),
  ("useAfter", testUseAfter),
  ("withRoutes", testWithRoutes)
  ]
