||| Type-safe routing and pure URL utilities.
module Iris.Router.Types

import Data.List

public export
interface Router (route : Type) where
  toUrl   : route -> String
  fromUrl : String -> Maybe route

public export
data NavCmd : (route : Type) -> Type where
  Push    : route -> NavCmd route
  Replace : route -> NavCmd route
  Back    : (n : Nat) -> NavCmd route
  Forward : (n : Nat) -> NavCmd route

public export
record NavState (route : Type) where
  constructor MkNavState
  back    : List route
  current : route
  forward : List route

public export
initNav : route -> NavState route
initNav route = MkNavState [] route []

public export
applyNav : NavCmd route -> NavState route -> NavState route
applyNav (Push route) state = MkNavState (state.current :: state.back) route []
applyNav (Replace route) state = MkNavState state.back route state.forward
applyNav (Back Z) state = state
applyNav (Back (S steps)) state =
  case state.back of
    [] => state
    previous :: rest =>
      applyNav (Back steps) (MkNavState rest previous (state.current :: state.forward))
applyNav (Forward Z) state = state
applyNav (Forward (S steps)) state =
  case state.forward of
    [] => state
    next :: rest =>
      applyNav (Forward steps) (MkNavState (state.current :: state.back) next rest)

public export
record Location where
  constructor MkLocation
  path     : String
  query    : List (String, String)
  fragment : Maybe String

splitFirst : Char -> List Char -> (List Char, List Char)
splitFirst separator = go []
  where
    go : List Char -> List Char -> (List Char, List Char)
    go acc [] = (reverse acc, [])
    go acc (char :: rest) =
      if char == separator then (reverse acc, rest) else go (char :: acc) rest

splitAll : Char -> List Char -> List (List Char)
splitAll separator = go []
  where
    go : List Char -> List Char -> List (List Char)
    go acc [] = [reverse acc]
    go acc (char :: rest) =
      if char == separator
         then reverse acc :: go [] rest
         else go (char :: acc) rest

hexValue : Char -> Maybe Int
hexValue char =
  if char >= '0' && char <= '9' then Just (ord char - ord '0')
  else if char >= 'a' && char <= 'f' then Just (10 + ord char - ord 'a')
  else if char >= 'A' && char <= 'F' then Just (10 + ord char - ord 'A')
  else Nothing

urlDecodeChars : Bool -> List Char -> Maybe (List Char)
urlDecodeChars _ [] = Just []
urlDecodeChars plusAsSpace ('+' :: rest) =
  map ((if plusAsSpace then ' ' else '+') ::) (urlDecodeChars plusAsSpace rest)
urlDecodeChars plusAsSpace ('%' :: hi :: lo :: rest) = do
  high <- hexValue hi
  low <- hexValue lo
  decoded <- urlDecodeChars plusAsSpace rest
  pure (chr (high * 16 + low) :: decoded)
urlDecodeChars _ ('%' :: _) = Nothing
urlDecodeChars plusAsSpace (char :: rest) =
  map (char ::) (urlDecodeChars plusAsSpace rest)

urlDecode : Bool -> List Char -> Maybe String
urlDecode plusAsSpace chars = map pack (urlDecodeChars plusAsSpace chars)

parseQueryPart : List Char -> Maybe (String, String)
parseQueryPart chars =
  let (key, value) = splitFirst '=' chars
  in [| MkPair (urlDecode True key) (urlDecode True value) |]

||| Parse a relative or absolute-path URL into decoded components. The caller
||| can reject malformed percent escapes rather than receiving partial data.
public export
parseLocation : String -> Maybe Location
parseLocation raw = do
  let (beforeFragment, fragmentChars) = splitFirst '#' (unpack raw)
  let (pathChars, queryChars) = splitFirst '?' beforeFragment
  decodedPath <- urlDecode False pathChars
  decodedQuery <- case queryChars of
                    [] => Just []
                    chars => traverse parseQueryPart (splitAll '&' chars)
  decodedFragment <- case fragmentChars of
                       [] => Just Nothing
                       chars => map Just (urlDecode False chars)
  pure (MkLocation (if decodedPath == "" then "/" else decodedPath)
                   decodedQuery decodedFragment)

public export
queryParam : String -> Location -> Maybe String
queryParam name location = lookup name location.query

trimSlashes : List Char -> List Char
trimSlashes = reverse . dropWhile (== '/') . reverse . dropWhile (== '/')

segments : String -> List String
segments value =
  case trimSlashes (unpack value) of
    [] => []
    chars => map pack (splitAll '/' chars)

||| Match a route pattern such as `/users/:id`. Literal segments must match
||| exactly; `:name` segments are returned as decoded path parameters.
public export
matchPath : String -> String -> Maybe (List (String, String))
matchPath pattern actual = match (segments pattern) (segments actual)
  where
    match : List String -> List String -> Maybe (List (String, String))
    match [] [] = Just []
    match (expected :: patterns) (value :: values) =
      case unpack expected of
        ':' :: name => map ((pack name, value) ::) (match patterns values)
        _ => if expected == value then match patterns values else Nothing
    match _ _ = Nothing
