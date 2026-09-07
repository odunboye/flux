module Flux.Server.Config

import public System
import public Data.SortedMap

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

-- Get integer value from config
export
getInt : String -> Config -> Maybe Integer
getInt key (MkConfig vals) =
  case lookup key vals of
    Just (ConfigInt i) => Just i
    _ => Nothing

-- Get boolean value from config
export
getBool : String -> Config -> Maybe Bool
getBool key (MkConfig vals) =
  case lookup key vals of
    Just (ConfigBool b) => Just b
    _ => Nothing

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

-- Load config from environment variables with prefix
export
loadFromEnv : String -> IO Config
loadFromEnv _ = pure empty

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

export
defaultServerConfig : ServerConfig
defaultServerConfig = MkServerConfig
  { host = "127.0.0.1"
  , port = 8080
  , workers = 4
  , timeout = 30000
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
  , maxBodySize = getIntDef "server.maxBodySize" defaultServerConfig.maxBodySize cfg
  , debug = getBoolDef "server.debug" defaultServerConfig.debug cfg
  }

-- Load server config from environment
export
serverConfigFromEnv : IO ServerConfig
serverConfigFromEnv = pure defaultServerConfig

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

-- Load app info from environment
export
appInfoFromEnv : IO AppInfo
appInfoFromEnv = pure defaultAppInfo
