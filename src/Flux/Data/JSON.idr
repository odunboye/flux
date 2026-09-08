module Flux.Data.JSON

import public Flux.Core.HTTP
import public Flux.Core.Middleware
import public Data.SortedMap
import public Data.List
import Data.String

%language ElabReflection

-- JSON value representation
public export
data JSON
  = JNull
  | JBool Bool
  | JNumber Double
  | JString String
  | JArray (List JSON)
  | JObject (SortedMap String JSON)

export partial
Eq JSON where
  JNull == JNull = True
  JBool x == JBool y = x == y
  JNumber x == JNumber y = x == y
  JString x == JString y = x == y
  JArray x == JArray y = x == y
  JObject x == JObject y = x == y
  _ == _ = False

-- ToJSON typeclass
public export
interface ToJSON a where
  toJSON : a -> JSON

-- FromJSON typeclass
public export
interface FromJSON a where
  fromJSON : JSON -> Maybe a

-- ToJSON instances
export
ToJSON Bool where
  toJSON = JBool

export
ToJSON Int where
  toJSON = JNumber . cast

export
ToJSON Integer where
  toJSON = JNumber . cast

export
ToJSON Double where
  toJSON = JNumber

export
ToJSON String where
  toJSON = JString

export
ToJSON JSON where
  toJSON = id

export
ToJSON a => ToJSON (List a) where
  toJSON = JArray . map toJSON

export
ToJSON a => ToJSON (SortedMap String a) where
  toJSON = JObject . map toJSON

-- FromJSON instances
export
FromJSON Bool where
  fromJSON (JBool b) = Just b
  fromJSON _         = Nothing

export
FromJSON Int where
  fromJSON (JNumber n) = Just (cast {to = Int} (floor n))
  fromJSON _           = Nothing

export
FromJSON Integer where
  fromJSON (JNumber n) = Just (cast {to = Integer} (floor n))
  fromJSON _           = Nothing

export
FromJSON Double where
  fromJSON (JNumber n) = Just n
  fromJSON _           = Nothing

export
FromJSON String where
  fromJSON (JString s) = Just s
  fromJSON _           = Nothing

export
FromJSON JSON where
  fromJSON = Just

export
FromJSON a => FromJSON (List a) where
  fromJSON (JArray xs) = traverse fromJSON xs
  fromJSON _           = Nothing

-- Escape special characters in strings
export
escapeString : String -> String
escapeString = concatMap escapeChar . unpack
  where
    escapeChar : Char -> String
    escapeChar '"'  = "\\\""
    escapeChar '\\' = "\\\\"
    escapeChar '\n' = "\\n"
    escapeChar '\r' = "\\r"
    escapeChar '\t' = "\\t"
    escapeChar c    = pack [c]

-- Simple JSON encoding.
-- `encode`/`encodeKV` recurse into `JObject`'s values via an opaque
-- `SortedMap`, so the termination checker can't see the structural
-- decrease; callers reach for `encode` via `assert_total` instead.
mutual
  export partial
  encode : JSON -> String
  encode JNull         = "null"
  encode (JBool True)  = "true"
  encode (JBool False) = "false"
  encode (JNumber n)   = show n
  encode (JString s)   = "\"" ++ escapeString s ++ "\""
  encode (JArray xs)   = "[" ++ joinBy ", " (map encode xs) ++ "]"
  encode (JObject kvs) = "{" ++ joinBy ", " (map encodeKV (toList kvs)) ++ "}"

  partial
  encodeKV : (String, JSON) -> String
  encodeKV (k, v) = "\"" ++ escapeString k ++ "\": " ++ encode v

-- JSON parsing
public export
data ParseError
  = UnexpectedEnd
  | UnexpectedChar Char
  | ExpectedString
  | ExpectedNumber
  | InvalidToken

export
Show ParseError where
  show UnexpectedEnd     = "Unexpected end of input"
  show (UnexpectedChar c) = "Unexpected character: " ++ pack [c]
  show ExpectedString    = "Expected string"
  show ExpectedNumber    = "Expected number"
  show InvalidToken      = "Invalid token"

export
ParseResult : Type -> Type
ParseResult a = Either ParseError (a, String)

-- Every function below that consumes more than a fixed number of
-- characters (a value, a string literal, a key/value pair) returns its
-- leftover input alongside its result - required for any of the
-- multi-element constructs (parseArray/parseObject) to advance past what
-- an inner parseValue/parseKV call actually consumed, rather than
-- re-parsing from the same position forever. An earlier version of this
-- parser didn't do this consistently (parseValue/parseTrue/parseFalse/
-- parseNull/the old parseKV/parseItems/parseKVs all discarded or never
-- tracked their leftover position) - it happened to typecheck and every
-- existing test still passed, because the only tests exercising the
-- string parser (TestJSON's testDecode/testDecodeNumber) decoded a bare
-- scalar ("true", "42.5"), never an array or object, so the broken
-- multi-element machinery was never actually run. Fixed here, with
-- TestJSON gaining coverage for exactly what was missing: multi-key
-- objects, multi-element arrays, and nesting.
mutual
  -- Parse JSON string
  export
  json : String -> Either ParseError JSON
  json input = case parseValue (unpack (trimStr input)) of
    Left e        => Left e
    Right (v,  _) => Right v

  trimStr : String -> String
  trimStr = pack . Data.List.dropWhile JSON.isSpace . unpack

  parseValue : List Char -> Either ParseError (JSON, List Char)
  parseValue [] = Left UnexpectedEnd
  parseValue (c :: cs) =
    if c == '{' then parseObject cs
    else if c == '[' then parseArray cs
    else if c == '"' then
      parseStringLit cs >>= \(s, rest) => Right (JString s, rest)
    else if c == 't' then parseTrue (c :: cs)
    else if c == 'f' then parseFalse (c :: cs)
    else if c == 'n' then parseNull (c :: cs)
    else if isDigit c || c == '-' then parseNumber (c :: cs)
    else if JSON.isSpace c then parseValue (Data.List.dropWhile JSON.isSpace cs)
    else Left (UnexpectedChar c)

  parseStringLit : List Char -> Either ParseError (String, List Char)
  parseStringLit = go ""
    where
      go : String -> List Char -> Either ParseError (String, List Char)
      go acc [] = Left UnexpectedEnd
      go acc (c :: rest) =
        -- acc is already in forward order (each char is snoc'd, i.e.
        -- appended, not consed) - reversing it here would undo that.
        if c == '"' then Right (acc, rest)
        else if c == '\\' then
          case rest of
            [] => Left UnexpectedEnd
            (n :: rs) =>
              let newAcc = case n of
                    'n' => Data.List.snoc (unpack acc) '\n'
                    'r' => Data.List.snoc (unpack acc) '\r'
                    't' => Data.List.snoc (unpack acc) '\t'
                    '"' => Data.List.snoc (unpack acc) '"'
                    '\\' => Data.List.snoc (unpack acc) '\\'
                    _ => Data.List.snoc (unpack acc) n
               in go (pack newAcc) rs
        else go (pack (Data.List.snoc (unpack acc) c)) rest

  parseNumber : List Char -> Either ParseError (JSON, List Char)
  parseNumber cs =
    let isNumChar : Char -> Bool
        isNumChar c = if isDigit c then True else c `Prelude.elem` ['.', '-', '+', 'e', 'E']
     in let (numChars, rest) = Data.List.break (not . isNumChar) cs
            numStr = pack numChars
         in case Data.ByteString.parseDouble (fromString numStr) of
              Just n  => Right (JNumber n, rest)
              Nothing => Left ExpectedNumber

  parseTrue : List Char -> Either ParseError (JSON, List Char)
  parseTrue ('t'::'r'::'u'::'e'::rest) = Right (JBool True, rest)
  parseTrue _ = Left InvalidToken

  parseFalse : List Char -> Either ParseError (JSON, List Char)
  parseFalse ('f'::'a'::'l'::'s'::'e'::rest) = Right (JBool False, rest)
  parseFalse _ = Left InvalidToken

  parseNull : List Char -> Either ParseError (JSON, List Char)
  parseNull ('n'::'u'::'l'::'l'::rest) = Right (JNull, rest)
  parseNull _ = Left InvalidToken

  parseArray : List Char -> Either ParseError (JSON, List Char)
  parseArray cs0 = case Data.List.dropWhile JSON.isSpace cs0 of
    (']' :: rest) => Right (JArray [], rest)
    cs            => firstItem [] cs

  firstItem : List JSON -> List Char -> Either ParseError (JSON, List Char)
  firstItem acc cs = do
    (v, rest) <- parseValue cs
    moreItems (v :: acc) rest

  moreItems : List JSON -> List Char -> Either ParseError (JSON, List Char)
  moreItems acc cs = case Data.List.dropWhile JSON.isSpace cs of
    (']' :: rest) => Right (JArray (reverse acc), rest)
    (',' :: rest) => firstItem acc (Data.List.dropWhile JSON.isSpace rest)
    _             => Left InvalidToken

  parseObject : List Char -> Either ParseError (JSON, List Char)
  parseObject cs0 = case Data.List.dropWhile JSON.isSpace cs0 of
    ('}' :: rest) => Right (JObject empty, rest)
    cs            => firstPair empty cs

  firstPair : SortedMap String JSON -> List Char -> Either ParseError (JSON, List Char)
  firstPair acc cs = do
    ((k,v), rest) <- parseKV cs
    morePairs (insert k v acc) rest

  morePairs : SortedMap String JSON -> List Char -> Either ParseError (JSON, List Char)
  morePairs acc cs = case Data.List.dropWhile JSON.isSpace cs of
    ('}' :: rest) => Right (JObject acc, rest)
    (',' :: rest) => firstPair acc (Data.List.dropWhile JSON.isSpace rest)
    _             => Left InvalidToken

  parseKV : List Char -> Either ParseError ((String, JSON), List Char)
  parseKV cs =
    case Data.List.dropWhile JSON.isSpace cs of
      ('"' :: rest0) => do
        (k, afterKey) <- parseStringLit rest0
        case Data.List.dropWhile JSON.isSpace afterKey of
          (':' :: rest2) => do
            (v, rest3) <- parseValue (Data.List.dropWhile JSON.isSpace rest2)
            Right ((k, v), rest3)
          _ => Left ExpectedString
      _ => Left ExpectedString

  isSpace : Char -> Bool
  isSpace c = c `Prelude.elem` [' ', '\t', '\n', '\r']

  cons : Char -> String -> String
  cons c s = pack (c :: unpack s)

-- Raw HTTP helpers (standalone, outside the Context/App pipeline)
export
jsonResponse : ToJSON a => a -> ByteString
jsonResponse a =
  let bodyStr = assert_total (encode (toJSON a))
      body = fromString bodyStr
      hs = [("Content-Type", "application/json"), ("Content-Length", show (length bodyStr))]
      header = encodeResponse 200 hs
   in fastConcat [header, body]

export
jsonError : Nat -> String -> ByteString
jsonError code msg =
  let bodyStr = assert_total (encode (JObject (fromList [("error", JString msg)])))
      body = fromString bodyStr
      hs = [("Content-Type", "application/json"), ("Content-Length", show (length bodyStr))]
      header = encodeResponse code hs
   in fastConcat [header, body]

-- Context helpers: set the response body/headers to a JSON value.
export
sendJSON : ToJSON a => a -> Context -> Context
sendJSON a = setHeader "Content-Type" "application/json" . send (fromString (assert_total (encode (toJSON a))))

export
sendJSONError : Nat -> String -> Context -> Context
sendJSONError code msg =
  setStatus code . sendJSON (JObject (fromList [("error", JString msg)]))

||| An `ErrorRenderer` (see `Flux.Core.Middleware.App.onError`) that renders
||| a caught `AppError` as a JSON `{"error": "..."}` body instead of the
||| plain-text `defaultErrorRenderer`. Register with `withErrorRenderer`.
export
jsonErrorRenderer : ErrorRenderer
jsonErrorRenderer err = sendJSONError err.status err.message

-- Decode JSON string to value
export
decode : FromJSON a => String -> Maybe a
decode s = case json s of
  Right j => fromJSON j
  Left _  => Nothing

-- Content type helper
export
isJSON : Request -> Bool
isJSON req =
  case req.type of
    Just "application/json" => True
    Just "application/json; charset=utf-8" => True
    _                       => False
