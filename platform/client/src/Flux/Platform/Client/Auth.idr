||| Portable account API commands. No server, PG or password-crypto dependency.
module Flux.Platform.Client.Auth

import public Flux.Platform.Client

%default covering

public export
record Account where
  constructor MkAccount
  id : String
  username : String

export
FromJSON Account where
  fromJSON = withObject "Account" $ \obj => MkAccount <$> field obj "id" <*> field obj "username"

public export
record Session where
  constructor MkSession
  account : Account
  token : String
  expiresAt : String

export
FromJSON Session where
  fromJSON = withObject "Session" $ \obj => MkSession <$> field obj "account" <*> field obj "token" <*> field obj "expiresAt"

credentials : String -> String -> JSON
credentials username password = JObject [("username",JString username),("password",JString password)]

export
register : {msg : Type} -> Client -> String -> String -> (Either RpcError Account -> msg) -> Cmd msg
register client username password = call client "/rpc/v1/auth/register" (credentials username password)

export
login : {msg : Type} -> Client -> String -> String -> (Either RpcError Session -> msg) -> Cmd msg
login client username password = call client "/rpc/v1/auth/login" (credentials username password)

||| Read-only validation of the bearer token. Never trust stored account metadata.
export
me : {msg : Type} -> Client -> (Either RpcError Account -> msg) -> Cmd msg
me client = call client "/rpc/v1/auth/me" (JObject [])

export
logout : {msg : Type} -> Client -> (Either RpcError JSON -> msg) -> Cmd msg
logout client = call client "/rpc/v1/auth/logout" (JObject [])
