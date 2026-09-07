module Flux.Core.Router

import public Flux.Core.HTTP
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

-- A route, generic over the handler representation `h` so this module has
-- no dependency on how handlers are actually run (see `Flux.Core.Middleware`).
public export
record Route h where
  constructor MkRoute
  method  : Method
  pattern : PathPattern
  handler : h

public export
record Router h where
  constructor MkRouter
  routes : List (Route h)

export
empty : Router h
empty = MkRouter []

-- Routes are matched in declaration order: append rather than prepend so
-- the first route added is the first one tried.
export
addRoute : Method -> String -> h -> Router h -> Router h
addRoute m pat h (MkRouter rs) = MkRouter (rs ++ [MkRoute m (parsePattern pat) h])

export
get : String -> h -> Router h -> Router h
get = addRoute GET

export
post : String -> h -> Router h -> Router h
post = addRoute POST

export
head_ : String -> h -> Router h -> Router h
head_ = addRoute HEAD

-- Find the first matching route
export
matchRoute : Method -> String -> Router h -> Maybe (PathParams, h)
matchRoute method path (MkRouter routes) = findRoute routes
  where
    findRoute : List (Route h) -> Maybe (PathParams, h)
    findRoute [] = Nothing
    findRoute (MkRoute m pat h :: rs) =
      if m == method then
        case matchPath pat path of
          Just params => Just (params, h)
          Nothing     => findRoute rs
      else findRoute rs
