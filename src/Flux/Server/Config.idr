module Flux.Server.Config

import public System
import public Data.SortedMap
import Data.String

%default total

-- Configuration value types
public export
data ConfigValue
  = ConfigString String
  | ConfigInt Integer
  | ConfigBool Bool
  | ConfigList (List ConfigValue)
  | ConfigObject (SortedMap String ConfigValue)

export partial
Show ConfigValue where
  showPrec _ (ConfigString s) = show s
  showPrec _ (ConfigInt i) = show i
  showPrec _ (ConfigBool True) = "true"
  showPrec _ (ConfigBool False) = "false"
  showPrec _ (ConfigList xs) = "[" ++ show xs ++ "]"
  showPrec _ (ConfigObject _) = "{...}"

-- Configuration environment
public export
record Config where
  constructor MkConfig
  values : SortedMap String ConfigValue

export
empty : Config
empty = MkConfig empty

-- Get string value from config
export
getString : String -> Config -> Maybe String
getString key (MkConfig vals) =
  case lookup key vals of
    Just (ConfigString s) => Just s
    _ => Nothing

-- Get integer value from config. Falls back to parsing a ConfigString,
-- since env-sourced values always arrive as strings.
export
getInt : String -> Config -> Maybe Integer
getInt key (MkConfig vals) =
  case lookup key vals of
    Just (ConfigInt i)    => Just i
    Just (ConfigString s) => parseInteger s
    _                     => Nothing

parseBoolStr : String -> Maybe Bool
parseBoolStr s = case toLower s of
  "true"  => Just True
  "1"     => Just True
  "false" => Just False
  "0"     => Just False
  _       => Nothing

-- Get boolean value from config. Falls back to parsing a ConfigString
-- ("true"/"1" -> True, "false"/"0" -> False), for the same reason as getInt.
export
getBool : String -> Config -> Maybe Bool
getBool key (MkConfig vals) =
  case lookup key vals of
    Just (ConfigBool b)   => Just b
    Just (ConfigString s) => parseBoolStr s
    _                     => Nothing

-- Get string with default
export
getStringDef : String -> String -> Config -> String
getStringDef key def cfg =
  maybe def id (getString key cfg)

-- Get integer with default
export
getIntDef : String -> Integer -> Config -> Integer
getIntDef key def cfg =
  maybe def id (getInt key cfg)

-- Get boolean with default
export
getBoolDef : String -> Bool -> Config -> Bool
getBoolDef key def cfg =
  maybe def id (getBool key cfg)

-- Set value in config
export
setString : String -> String -> Config -> Config
setString key val (MkConfig vals) =
  MkConfig (insert key (ConfigString val) vals)

export
setInt : String -> Integer -> Config -> Config
setInt key val (MkConfig vals) =
  MkConfig (insert key (ConfigInt val) vals)

export
setBool : String -> Bool -> Config -> Config
setBool key val (MkConfig vals) =
  MkConfig (insert key (ConfigBool val) vals)

-- Normalize an env var name into a Config key: lowercase, "_" -> ".", so
-- e.g. "SERVER_HOST" -> "server.host".
normalizeKey : String -> String
normalizeKey = pack . map (\c => if c == '_' then '.' else c) . unpack . toLower

addEnvVar : String -> Config -> (String, String) -> Config
addEnvVar pfx cfg (k, v) =
  if pfx `isPrefixOf` k
    then setString (normalizeKey (substr (length pfx) (length k) k)) v cfg
    else cfg

-- Load config from environment variables whose name starts with `prefix`
-- (e.g. "FLUX_"), stripping the prefix and normalizing what's left into a
-- dotted lowercase key. Values are always stored as ConfigString, since
-- that's all an environment variable can be - getInt/getBool parse them.
export covering
loadFromEnv : String -> IO Config
loadFromEnv pfx = do
  vars <- getEnvironment
  pure $ foldl (addEnvVar pfx) empty vars

-- Common server configuration
public export
record ServerConfig where
  constructor MkServerConfig
  host         : String
  port         : Bits16
  workers      : Nat
  timeout      : Integer
  maxBodySize  : Integer
  debug        : Bool

-- workers/timeout match runServerArgs/idleConnectionTimeout's own
-- defaults (Flux.Core.HTTP) deliberately: this record's fields were
-- inert until Flux.Core.HTTP.runServerFromConfig started reading them,
-- so keeping the numbers in sync means adopting runServerFromConfig with
-- no env vars set is behavior-neutral rather than a silent regression
-- (4 workers, a 30s idle timeout) against what runServer/runServerArgs
-- already do. maxBodySize is the one deliberate exception - see its own
-- note below.
export
defaultServerConfig : ServerConfig
defaultServerConfig = MkServerConfig
  { host = "127.0.0.1"
  , port = 8080
  , workers = 128
  , timeout = 60000
  -- Deliberately far tighter than runServer's effectively-unlimited
  -- ~4GB (MaxContentSize, Flux.Core.HTTP) - 1MB is a sane cap to actually
  -- have by default, once this field started doing something.
  , maxBodySize = 1048576  -- 1MB
  , debug = False
  }

-- Parse server config from Config
export
serverConfigFrom : Config -> ServerConfig
serverConfigFrom cfg = MkServerConfig
  { host = getStringDef "server.host" defaultServerConfig.host cfg
  , port = cast (getIntDef "server.port" (cast defaultServerConfig.port) cfg)
  , workers = cast (getIntDef "server.workers" (cast defaultServerConfig.workers) cfg)
  , timeout = getIntDef "server.timeout" defaultServerConfig.timeout cfg
  , maxBodySize = getIntDef "server.maxbodysize" defaultServerConfig.maxBodySize cfg
  , debug = getBoolDef "server.debug" defaultServerConfig.debug cfg
  }

-- Load server config from environment variables prefixed "FLUX_", e.g.
-- FLUX_SERVER_PORT=9090 -> "server.port" -> ServerConfig.port.
export covering
serverConfigFromEnv : IO ServerConfig
serverConfigFromEnv = serverConfigFrom <$> loadFromEnv "FLUX_"

-- Application metadata
public export
record AppInfo where
  constructor MkAppInfo
  name    : String
  version : String
  env     : String  -- "development", "staging", "production"

export
defaultAppInfo : AppInfo
defaultAppInfo = MkAppInfo
  { name = "flux-app"
  , version = "0.1.0"
  , env = "development"
  }

-- Parse app info from Config
export
appInfoFrom : Config -> AppInfo
appInfoFrom cfg = MkAppInfo
  { name    = getStringDef "app.name" defaultAppInfo.name cfg
  , version = getStringDef "app.version" defaultAppInfo.version cfg
  , env     = getStringDef "app.env" defaultAppInfo.env cfg
  }

-- Load app info from environment variables prefixed "FLUX_", e.g.
-- FLUX_APP_ENV=production -> "app.env" -> AppInfo.env.
export covering
appInfoFromEnv : IO AppInfo
appInfoFromEnv = appInfoFrom <$> loadFromEnv "FLUX_"
