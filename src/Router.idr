module Router

import public HTTP
import public Data.SortedMap
import public Data.List

%default total

-- Path parameter extraction
public export
record PathParams where
  constructor MkParams
  params : SortedMap String String

export
emptyParams : PathParams
emptyParams = MkParams empty

export
getParam : String -> PathParams -> Maybe String
getParam name (MkParams ps) = lookup name ps

-- Route pattern types
public export
data PathSegment = Literal String | Param String

export
Eq PathSegment where
  Literal x == Literal y = x == y
  Param x == Param y = x == y
  _ == _ = False

public export
PathPattern : Type
PathPattern = List PathSegment

-- Split string on character
splitOn : Char -> String -> List String
splitOn c str =
  foldr go [""] (unpack str)
  where
    go : Char -> List String -> List String
    go x acc =
      if x == c then
        "" :: acc
      else
        case acc of
          [] => [""]
          (h :: t) => (strCons x h) :: t
    strCons : Char -> String -> String
    strCons x s = pack (x :: unpack s)

-- Parse path pattern string like "/users/:id/posts"
export
parsePattern : String -> PathPattern
parsePattern pat = map parseSeg (splitOn '/' pat)
  where
    parseSeg : String -> PathSegment
    parseSeg str =
      case unpack str of
        [] => Literal ""
        (':' :: cs) => Param (pack cs)
        _ => Literal str

-- Match a path against a pattern
export
matchPath : PathPattern -> String -> Maybe PathParams
matchPath pattern path =
  let segments := splitOn '/' path
   in matchSegments pattern segments empty
  where
    matchSegments : List PathSegment -> List String -> SortedMap String String -> Maybe PathParams
    matchSegments [] [] acc = Just (MkParams acc)
    matchSegments [] _  _   = Nothing
    matchSegments _  [] _   = Nothing
    matchSegments (Literal lit :: ps) (seg :: segs) acc =
      if lit == seg then matchSegments ps segs acc else Nothing
    matchSegments (Param name :: ps) (seg :: segs) acc =
      matchSegments ps segs (insert name seg acc)

-- Handler type - returns ByteString response
public export
Handler : Type
Handler = Request -> ByteString

-- Route definition
public export
record Route where
  constructor MkRoute
  method  : Method
  pattern : PathPattern
  handler : Handler

-- Router state
public export
record Router where
  constructor MkRouter
  routes : List Route

export
empty : Router
empty = MkRouter []

export
addRoute : Method -> String -> Handler -> Router -> Router
addRoute m pat h (MkRouter rs) = MkRouter (MkRoute m (parsePattern pat) h :: rs)

export
get : String -> Handler -> Router -> Router
get = addRoute GET

export
post : String -> Handler -> Router -> Router
post = addRoute POST

export
head_ : String -> Handler -> Router -> Router
head_ = addRoute HEAD

-- Find matching route
export
matchRoute : Method -> String -> Router -> Maybe (PathParams, Handler)
matchRoute method path (MkRouter routes) = findRoute routes
  where
    findRoute : List Route -> Maybe (PathParams, Handler)
    findRoute [] = Nothing
    findRoute (MkRoute m pat h :: rs) =
      if m == method then
        case matchPath pat path of
          Just params => Just (params, h)
          Nothing     => findRoute rs
      else findRoute rs

-- Create response from handler result
export
handleRoute : Router -> Request -> ByteString
handleRoute router req =
  case matchRoute req.method req.uri router of
    Just (params, handler) =>
      handler req
    Nothing =>
      fastConcat [encodeResponse 404 [("Content-Length", "9")], fromString "Not Found"]

-- Convenience route builders
export
route : Router -> Router
route = id

export
(|>) : Router -> (Router -> Router) -> Router
(|>) r f = f r
