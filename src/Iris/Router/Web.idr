||| Browser-history integration for typed Iris routes.
module Iris.Router.Web

import Iris.Router.Types

%foreign "javascript:lambda: _w => window.location.pathname + window.location.search + window.location.hash"
prim_location : PrimIO String

%foreign "javascript:lambda: (url,_w) => { history.pushState(null,'',url); dispatchEvent(new PopStateEvent('popstate')); }"
prim_push : String -> PrimIO ()

%foreign "javascript:lambda: (url,_w) => { history.replaceState(null,'',url); dispatchEvent(new PopStateEvent('popstate')); }"
prim_replace : String -> PrimIO ()

%foreign "javascript:lambda: (amount,_w) => history.go(-amount)"
prim_back : Int -> PrimIO ()

%foreign "javascript:lambda: (amount,_w) => history.go(amount)"
prim_forward : Int -> PrimIO ()

public export
currentLocation : IO String
currentLocation = primIO prim_location

public export
currentRoute : {route : Type} -> Router route => IO (Maybe route)
currentRoute = map fromUrl currentLocation

public export
runNavigation : {route : Type} -> Router route => NavCmd route -> IO ()
runNavigation (Push route) = primIO (prim_push (toUrl route))
runNavigation (Replace route) = primIO (prim_replace (toUrl route))
runNavigation (Back amount) = primIO (prim_back (cast amount))
runNavigation (Forward amount) = primIO (prim_forward (cast amount))
