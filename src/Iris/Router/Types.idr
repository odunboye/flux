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

escapedBytes : List Char -> Maybe (List Int, List Char)
escapedBytes ('%' :: high :: low :: rest) = do
  hi <- hexValue high
  lo <- hexValue low
  let byte = hi * 16 + lo
  case rest of
    '%' :: _ => do
      (bytes, remaining) <- escapedBytes rest
      pure (byte :: bytes, remaining)
    _ => pure ([byte], rest)
escapedBytes _ = Nothing

continuation : Int -> Bool
continuation byte = byte >= 128 && byte <= 191

utf8Chars : List Int -> Maybe (List Char)
utf8Chars [] = Just []
utf8Chars (first :: rest) =
  if first <= 127 then map (chr first ::) (utf8Chars rest)
  else case rest of
    second :: remaining =>
      if first >= 194 && first <= 223 && continuation second
         then emit ((first - 192) * 64 + (second - 128)) remaining
      else case remaining of
        third :: afterThree =>
          if first >= 224 && first <= 239 && continuation second && continuation third &&
             (first /= 224 || second >= 160) && (first /= 237 || second <= 159)
             then emit ((first - 224) * 4096 + (second - 128) * 64 +
                        (third - 128)) afterThree
          else case afterThree of
            fourth :: afterFour =>
              if first >= 240 && first <= 244 && continuation second &&
                 continuation third && continuation fourth &&
                 (first /= 240 || second >= 144) && (first /= 244 || second <= 143)
                 then emit ((first - 240) * 262144 + (second - 128) * 4096 +
                            (third - 128) * 64 + (fourth - 128)) afterFour
                 else Nothing
            [] => Nothing
        [] => Nothing
    [] => Nothing
  where
    emit : Int -> List Int -> Maybe (List Char)
    emit code remaining = map (chr code ::) (utf8Chars remaining)

urlDecodeChars : Bool -> List Char -> Maybe (List Char)
urlDecodeChars _ [] = Just []
urlDecodeChars plusAsSpace ('+' :: rest) =
  map ((if plusAsSpace then ' ' else '+') ::) (urlDecodeChars plusAsSpace rest)
urlDecodeChars plusAsSpace chars@('%' :: _) = do
  (bytes, rest) <- escapedBytes chars
  unicode <- utf8Chars bytes
  decoded <- urlDecodeChars plusAsSpace rest
  pure (unicode ++ decoded)
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

hexDigit : Int -> Char
hexDigit value =
  if value < 10 then chr (ord '0' + value) else chr (ord 'A' + value - 10)

percentByte : Int -> List Char
percentByte byte = ['%', hexDigit (byte `div` 16), hexDigit (byte `mod` 16)]

utf8Bytes : Char -> List Int
utf8Bytes char =
  let code = ord char in
  if code <= 127 then [code]
  else if code <= 2047 then
    [192 + code `div` 64, 128 + code `mod` 64]
  else if code <= 65535 then
    [224 + code `div` 4096, 128 + (code `div` 64) `mod` 64, 128 + code `mod` 64]
  else
    [240 + code `div` 262144, 128 + (code `div` 4096) `mod` 64,
     128 + (code `div` 64) `mod` 64, 128 + code `mod` 64]

unreserved : Char -> Bool
unreserved char =
  (char >= 'a' && char <= 'z') || (char >= 'A' && char <= 'Z') ||
  (char >= '0' && char <= '9') || elem char ['-', '.', '_', '~']

encodeComponent : Bool -> String -> String
encodeComponent allowSlash value = pack (concatMap encodeChar (unpack value))
  where
    encodeChar : Char -> List Char
    encodeChar char =
      if unreserved char || (allowSlash && char == '/') then [char]
      else concatMap percentByte (utf8Bytes char)

public export
renderLocation : Location -> String
renderLocation location =
  let path = if location.path == "" then "/" else encodeComponent True location.path
      queryString = case location.query of
        [] => ""
        values => "?" ++ joinQuery values
      fragmentString = case location.fragment of
        Nothing => ""
        Just value => "#" ++ encodeComponent False value
  in path ++ queryString ++ fragmentString
  where
    joinQuery : List (String, String) -> String
    joinQuery [] = ""
    joinQuery [(key, value)] = encodeComponent False key ++ "=" ++ encodeComponent False value
    joinQuery ((key, value) :: rest) = encodeComponent False key ++ "=" ++
      encodeComponent False value ++ "&" ++ joinQuery rest

public export
withBasePath : String -> String -> String
withBasePath base path =
  let cleanBase = pack (reverse (dropWhile (== '/') (reverse (unpack base))))
      cleanPath = pack (dropWhile (== '/') (unpack path))
  in if cleanBase == "" then "/" ++ cleanPath else cleanBase ++ "/" ++ cleanPath

public export
stripBasePath : String -> String -> Maybe String
stripBasePath base path =
  let basePrefix = withBasePath base ""
  in if base == "" then Just path
     else if path == base then Just "/"
     else if substr 0 (length basePrefix) path == basePrefix
             then Just ("/" ++ substr (length basePrefix) (length path `minus` length basePrefix) path)
             else Nothing

public export
data RouteResolution route = Matched route | NotFound Location | MalformedLocation

public export
resolveRoute : {route : Type} -> Router route => String -> RouteResolution route
resolveRoute raw =
  case parseLocation raw of
    Nothing => MalformedLocation
    Just location => case fromUrl raw of
      Nothing => NotFound location
      Just route => Matched route

public export
data NavigationDecision route = Allow route | Redirect route | Block

public export
applyNavigationGuard : (route -> NavigationDecision route) -> route -> Maybe route
applyNavigationGuard guard route =
  case guard route of
    Allow target => Just target
    Redirect target => Just target
    Block => Nothing
