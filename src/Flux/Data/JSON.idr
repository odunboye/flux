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

mutual
  -- Parse JSON string
  export
  json : String -> Either ParseError JSON
  json input = parseValue (unpack (trimStr input))

  trimStr : String -> String
  trimStr = pack . Data.List.dropWhile JSON.isSpace . unpack

  parseValue : List Char -> Either ParseError JSON
  parseValue [] = Left UnexpectedEnd
  parseValue (c :: cs) =
    if c == '{' then parseObject cs
    else if c == '[' then parseArray cs
    else if c == '"' then
      parseStringLit cs >>= \(s, _) => pure (JString s)
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
        if c == '"' then Right (reverse acc, rest)
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

  parseNumber : List Char -> Either ParseError JSON
  parseNumber cs =
    let isNumChar : Char -> Bool
        isNumChar c = if isDigit c then True else c `Prelude.elem` ['.', '-', '+', 'e', 'E']
     in let (numChars, rest) = Data.List.break (not . isNumChar) cs
            numStr = pack numChars
         in case Data.ByteString.parseDouble (fromString numStr) of
              Just n  => Right (JNumber n)
              Nothing => Left ExpectedNumber

  parseTrue : List Char -> Either ParseError JSON
  parseTrue ('t'::'r'::'u'::'e'::rest) = Right (JBool True)
  parseTrue _ = Left InvalidToken

  parseFalse : List Char -> Either ParseError JSON
  parseFalse ('f'::'a'::'l'::'s'::'e'::rest) = Right (JBool False)
  parseFalse _ = Left InvalidToken

  parseNull : List Char -> Either ParseError JSON
  parseNull ('n'::'u'::'l'::'l'::rest) = Right (JNull)
  parseNull _ = Left InvalidToken

  parseArray : List Char -> Either ParseError JSON
  parseArray = parseItems []
    where
      parseItems : List JSON -> List Char -> Either ParseError JSON
      parseItems acc [] = Left UnexpectedEnd
      parseItems acc (']' :: rest) = Right (JArray (reverse acc))
      parseItems acc (',' :: rest) = parseItems acc rest
      parseItems acc (_ :: rest) = parseValue rest >>= \v => parseItems (v :: acc) rest
      parseItems acc _ = Left UnexpectedEnd

  parseObject : List Char -> Either ParseError JSON
  parseObject = parseKVs empty

  parseKV : List Char -> Either ParseError (String, JSON)
  parseKV cs = do
    (k, afterKey) <- parseStringLit (Data.List.dropWhile JSON.isSpace cs)
    case afterKey of
      [] => Left UnexpectedEnd
      (_ :: rest1) =>
        let afterColon = Data.List.dropWhile JSON.isSpace rest1
         in case afterColon of
              (':' :: rest2) => do
                v <- parseValue (Data.List.dropWhile JSON.isSpace rest2)
                pure (k, v)
              _ => Left ExpectedString

  parseKVs : SortedMap String JSON -> List Char -> Either ParseError JSON
  parseKVs acc [] = Left UnexpectedEnd
  parseKVs acc ('}' :: rest) = Right (JObject acc)
  parseKVs acc (',' :: rest) = parseKVs acc rest
  parseKVs acc cs = parseKV cs >>= \(k, v) => parseKVs (insert k v acc) cs

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
