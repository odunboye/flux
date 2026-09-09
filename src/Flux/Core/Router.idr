module Flux.Core.Router

import public Flux.Core.HTTP
import public Data.SortedMap
import public Data.List
import Data.String

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

-- Route pattern types. `Splat` (written `*name` in a pattern) consumes all
-- remaining path segments (joined with "/"); it only makes sense as the
-- last segment of a pattern - any pattern segments after it are never
-- reached, since a Splat always matches regardless of what's left.
public export
data PathSegment = Literal String | Param String | Splat String

export
Eq PathSegment where
  Literal x == Literal y = x == y
  Param x == Param y = x == y
  Splat x == Splat y = x == y
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
        ('*' :: cs) => Splat (pack cs)
        _ => Literal str

-- Match a path against a pattern. Segments are percent-decoded once,
-- upfront - both `Literal` and `Param` matching then see the same
-- decoded text (so a pattern segment like "users" matches an incoming
-- "user%73" the same way it matches a literal "users"), and a `Splat`'s
-- joined value is already decoded rather than carrying raw "%XX" escapes
-- through to the handler.
export
matchPath : PathPattern -> String -> Maybe PathParams
matchPath pattern path =
  let segments := map percentDecode (splitOn '/' path)
   in matchSegments pattern segments empty
  where
    matchSegments : List PathSegment -> List String -> SortedMap String String -> Maybe PathParams
    matchSegments (Splat name :: _) segs acc =
      Just (MkParams (insert name (joinBy "/" segs) acc))
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

export
put : String -> h -> Router h -> Router h
put = addRoute PUT

export
delete : String -> h -> Router h -> Router h
delete = addRoute DELETE

export
patch : String -> h -> Router h -> Router h
patch = addRoute PATCH

export
options_ : String -> h -> Router h -> Router h
options_ = addRoute OPTIONS

||| The result of matching a request against a `Router`: a genuine match,
||| a path match with no route for this particular method (carrying the
||| methods that *would* have matched, for a 405 response's `Allow`
||| header), or no route registered for this path at all.
public export
data MatchResult h = Matched PathParams h | WrongMethod (List Method) | NoMatch

-- Find the first matching route, in declaration order, for exactly the
-- given method. A route whose path matches but whose method doesn't is
-- remembered (not discarded) so callers can tell a 405 (wrong method)
-- apart from a genuine 404 (no such path).
matchExact : Method -> String -> Router h -> MatchResult h
matchExact method path (MkRouter routes) = go routes []
  where
    go : List (Route h) -> List Method -> MatchResult h
    go []                        []      = NoMatch
    go []                        allowed = WrongMethod allowed
    go (MkRoute m pat h :: rs) allowed =
      case matchPath pat path of
        Nothing     => go rs allowed
        Just params => if m == method then Matched params h else go rs (allowed ++ [m])

-- `Allow`/`WrongMethod` should list HEAD wherever GET is allowed, since
-- HEAD now implicitly works wherever GET does (see `matchRoute`) - for
-- *any* method's wrong-method result, not just a HEAD request's own.
addImplicitHead : List Method -> List Method
addImplicitHead ms = if elem GET ms && not (elem HEAD ms) then ms ++ [HEAD] else ms

||| Matches a request against a `Router`. A HEAD request falls back to a
||| matching GET route if no route was registered specifically for HEAD
||| (RFC 9110 §9.3.2: a HEAD response is defined identically to what GET
||| would produce, just without a body - `Flux.Core.Middleware.render`
||| already suppresses the body correctly for any HEAD request,
||| regardless of which route matched, since it reads the *request's*
||| own method, not anything the router decided). Register a route via
||| `head_` explicitly to override this with custom HEAD-specific
||| behavior - an exact HEAD match always wins over the GET fallback.
export
matchRoute : Method -> String -> Router h -> MatchResult h
matchRoute method path router = normalize $ case method of
  HEAD => case matchExact HEAD path router of
    Matched params h => Matched params h
    headResult        => case matchExact GET path router of
      Matched params h => Matched params h
      _                 => headResult
  _ => matchExact method path router
  where
    normalize : MatchResult h -> MatchResult h
    normalize (WrongMethod ms) = WrongMethod (addImplicitHead ms)
    normalize r                = r
