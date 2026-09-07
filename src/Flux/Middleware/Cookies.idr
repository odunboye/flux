module Flux.Middleware.Cookies

import public Flux.Core.HTTP
import public Flux.Core.Middleware
import Data.List1
import Data.String

%default total

||| Parses the request's `Cookie` header ("name1=value1; name2=value2")
||| into a map. Returns an empty map if there's no such header, or for any
||| segment that isn't a well-formed `name=value` pair.
export
parseCookies : Request -> SortedMap String String
parseCookies req = maybe empty parsePairs (lookup "cookie" req.headers)
  where
    insertPair : SortedMap String String -> String -> SortedMap String String
    insertPair acc kv = case break (== '=') (trim kv) of
      (k, v) => case strUncons v of
        Just (_, val) => insert k val acc
        Nothing       => acc

    parsePairs : String -> SortedMap String String
    parsePairs s = foldl insertPair empty (forget (split (== ';') s))

||| Reads one cookie from the request.
export
getCookie : String -> Context -> Maybe String
getCookie name ctx = lookup name (parseCookies ctx.request)

||| Sets a cookie on the response, using `cookie`'s defaults (root path,
||| HttpOnly, session-lifetime, not Secure). For anything else, build a
||| `SetCookie` yourself and use `Flux.Core.Middleware.addCookie`.
export
setCookie : String -> String -> Context -> Context
setCookie name value = addCookie (cookie name value)
