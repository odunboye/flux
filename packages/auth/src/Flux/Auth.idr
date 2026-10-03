module Flux.Auth

import public Flux.Platform.Endpoint
import public Flux.Auth.Schema
import Flux.Auth.Crypto
import Flux.DB.PG
import Data.PGPool
import Data.PGValue
import Data.SortedMap
import Data.List
import Data.Maybe
import Data.String

%default covering

export
record AuthService where
  constructor MkAuthService
  pool : Pool
  lifetime : Nat
  dummy : String

||| Startup only. Pool belongs to the application. TTL: 1 second through 30 days.
export
newAuthService : Pool -> Nat -> IO (Either String AuthService)
newAuthService pool lifetime =
  if lifetime == 0 || lifetime > 2592000 then pure (Left "Invalid session lifetime") else do
    Just dummy <- newDummy | Nothing => pure (Left "Authentication initialization failed")
    pure (Right (MkAuthService pool lifetime dummy))

-- Do NOT use dbFail/dbIO here: PostgreSQL error detail can contain credentials.
-- Store errors are intentionally not logged or reflected, even on stderr.
store : AuthService -> (DB -> IO (Either PGError a)) -> AppProg a
store service action = do
  Right result <- blocking (withConnectionIO service.pool action)
    | Left _ => throw (MkAppError 503 "Authentication unavailable")
  Right value <- pure result | Left _ => throw (MkAppError 500 "Authentication unavailable")
  pure value

textField : Row -> String -> AppProg String
textField row name = case columnByName row name of
  Just (Just value) => pure value
  _ => throw (MkAppError 500 "Authentication unavailable")

public export
record Credentials where
  constructor MkCredentials
  username : String
  password : String

export
FromJSON Credentials where
  fromJSON = withObject "Credentials" $ \obj => MkCredentials <$> field obj "username" <*> field obj "password"

public export
record AccountView where
  constructor MkAccountView
  id : String
  username : String

export
ToJSON AccountView where
  toJSON a = JObject [("id", JString a.id), ("username", JString a.username)]

public export
record SessionView where
  constructor MkSessionView
  account : AccountView
  token : String
  expiresAt : String

export
ToJSON SessionView where
  toJSON s = JObject [("account", toJSON s.account), ("token", JString s.token), ("expiresAt", JString s.expiresAt)]

canonicalName : String -> Maybe String
canonicalName value =
  let cs = unpack value in
    if length cs < 3 || length cs > 64 || not (all (\c =>
      (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
      (c >= '0' && c <= '9') || c == '-' || c == '_') cs)
      then Nothing else Just (toLower value)

unauthenticated : AppProg a
unauthenticated = throw (MkAppError 401 "Invalid credentials")

export
register : AuthService -> Credentials -> AppProg AccountView
register service input = do
  Just name <- pure (canonicalName input.username)
    | Nothing => throw (MkAppError 400 "Username must contain 3 to 64 ASCII letters, digits, hyphens or underscores")
  unless (validPassword input.password) (throw (MkAppError 400 "Password must contain 15 to 256 characters without NUL"))
  encoded <- hashPassword input.password
  rows <- store service (\db => queryRows db
    "INSERT INTO flux_auth_accounts (username,password_hash) VALUES ($1,$2) ON CONFLICT (username) DO NOTHING RETURNING id" [Just name, Just encoded])
  case rows of
    [row] => do
      uid <- textField row "id"
      pure (MkAccountView uid name)
    [] => throw (MkAppError 409 "Account unavailable")
    _ => throw (MkAppError 500 "Authentication unavailable")

-- Serialize issuance with account version changes. A password or logout-all
-- racing verification cannot mint a new session from an obsolete snapshot.
issue : AuthService -> String -> String -> String -> String -> IO (Either PGError (List Row))
issue service uid version encoded digest = withConnectionIO service.pool $ \db => withTransaction db $ do
  Right locked <- queryRows db "SELECT id FROM flux_auth_accounts WHERE id=$1 AND auth_version=$2 AND password_hash=$3 FOR UPDATE" [Just uid, Just version, Just encoded]
    | Left err => pure (Left err)
  case locked of
    [_] => do
      Right _ <- execCommandPrepared db "DELETE FROM flux_auth_sessions WHERE account_id=$1 AND expires_at <= clock_timestamp()" [Just uid]
        | Left err => pure (Left err)
      queryRows db "INSERT INTO flux_auth_sessions (digest,account_id,expires_at) SELECT $1,$2,clock_timestamp()+($3::integer * interval '1 second') WHERE (SELECT count(*) FROM flux_auth_sessions WHERE account_id=$2) < 32 RETURNING to_char(expires_at AT TIME ZONE 'UTC','YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"') AS expires" [Just digest, Just uid, Just (show service.lifetime)]
    [] => pure (Right [])
    _ => pure (Left (ConnectionError "Invalid account state"))

export
login : AuthService -> Credentials -> AppProg SessionView
login service input = do
  Just name <- pure (canonicalName input.username) | Nothing => unauthenticated
  unless (boundedPassword input.password) unauthenticated
  -- Ten attempts/minute/account, counted atomically and retained across restart.
  -- Locked and unknown accounts use the same dummy verification and 401 envelope.
  rows <- store service (\db => queryRows db
    "UPDATE flux_auth_accounts SET attempts=CASE WHEN attempt_window <= clock_timestamp()-interval '1 minute' THEN 1 ELSE LEAST(attempts+1,11) END, attempt_window=CASE WHEN attempt_window <= clock_timestamp()-interval '1 minute' THEN clock_timestamp() ELSE attempt_window END WHERE username=$1 RETURNING id,password_hash,auth_version,attempts <= 10 AS allowed" [Just name])
  case rows of
    [row] => do
      allowed <- textField row "allowed"
      True <- pure (allowed == "t")
        | False => do
          _ <- verifyPassword input.password service.dummy
          unauthenticated
      do
        encoded <- textField row "password_hash"
        True <- verifyPassword input.password encoded | False => unauthenticated
        uid <- textField row "id"
        version <- textField row "auth_version"
        Just token <- liftIO newToken | Nothing => throw (MkAppError 500 "Authentication unavailable")
        Just digest <- liftIO (tokenDigest token) | Nothing => throw (MkAppError 500 "Authentication unavailable")
        Right result <- blocking (issue service uid version encoded digest)
          | Left _ => throw (MkAppError 503 "Authentication unavailable")
        Right [session] <- pure result
          | Right [] => throw (MkAppError 401 "Session unavailable")
          | Left _ => throw (MkAppError 500 "Authentication unavailable")
          | _ => throw (MkAppError 500 "Authentication unavailable")
        expires <- textField session "expires"
        pure (MkSessionView (MkAccountView uid name) token expires)
    [] => do
      _ <- verifyPassword input.password service.dummy
      unauthenticated
    _ => throw (MkAppError 500 "Authentication unavailable")

record VerifiedSession where
  constructor MkVerifiedSession
  digest : String
  account : AccountView

credential : Request -> Maybe String
credential request = do
  raw <- lookup "authorization" request.headers
  case words raw of
    [scheme, value] => if toLower scheme == "bearer" && validToken value then Just value else Nothing
    _ => Nothing

resolve : AuthService -> Request -> AppProg (Maybe VerifiedSession)
resolve service request = case credential request of
  Nothing => pure Nothing
  Just token => do
    Just digest <- liftIO (tokenDigest token) | Nothing => throw (MkAppError 500 "Authentication unavailable")
    rows <- store service (\db => queryRows db
      "SELECT a.id,a.username FROM flux_auth_sessions s JOIN flux_auth_accounts a ON a.id=s.account_id WHERE s.digest=$1 AND s.expires_at > clock_timestamp()" [Just digest])
    case rows of
      [] => pure Nothing
      [row] => do
        uid <- textField row "id"
        name <- textField row "username"
        pure (Just (MkVerifiedSession digest (MkAccountView uid name)))
      _ => throw (MkAppError 500 "Authentication unavailable")

export
authenticator : AuthService -> Authenticator
authenticator service request = map (\s => MkPrincipal s.account.id) <$> resolve service request

requireSession : AuthService -> Request -> AppProg VerifiedSession
requireSession service request = do
  Just session <- resolve service request | Nothing => throw (MkAppError 401 "Authentication required")
  pure session

-- Serialize global revocation with issuance on the account row, then delete.
revokeAll : DB -> String -> IO (Either PGError ())
revokeAll db uid = withTransaction db $ do
  Right _ <- execCommandPrepared db "UPDATE flux_auth_accounts SET auth_version=auth_version+1 WHERE id=$1" [Just uid]
    | Left err => pure (Left err)
  Right _ <- execCommandPrepared db "DELETE FROM flux_auth_sessions WHERE account_id=$1" [Just uid]
    | Left err => pure (Left err)
  pure (Right ())

data EmptyRequest = MkEmptyRequest

FromJSON EmptyRequest where
  fromJSON = withObject "EmptyRequest" $ \_ => pure MkEmptyRequest

logoutHandler : AuthService -> Bool -> Handler
logoutHandler service all ctx = do
  session <- requireSession service ctx.request
  let action : EmptyRequest -> AppProg JSON
      action _ = do
        if all then store service (\db => revokeAll db session.account.id)
          else ignore (store service (\db => execCommandPrepared db "DELETE FROM flux_auth_sessions WHERE digest=$1 AND account_id=$2" [Just session.digest, Just session.account.id]))
        pure (JObject [("loggedOut", toJSON True)])
  rpcHandler action (setHeader "Cache-Control" "no-store" ctx)

meHandler : AuthService -> Handler
meHandler service ctx = do
  session <- requireSession service ctx.request
  let action : EmptyRequest -> AppProg AccountView
      action _ = pure session.account
  rpcHandler action (setHeader "Cache-Control" "no-store" ctx)

record PasswordChange where
  constructor MkPasswordChange
  currentPassword : String
  newPassword : String

FromJSON PasswordChange where
  fromJSON = withObject "PasswordChange" $ \obj => MkPasswordChange <$> field obj "currentPassword" <*> field obj "newPassword"

changePassword : AuthService -> VerifiedSession -> PasswordChange -> AppProg JSON
changePassword service session input = do
  unless (validPassword input.newPassword) (throw (MkAppError 400 "Password must contain 15 to 256 characters without NUL"))
  unless (boundedPassword input.currentPassword) unauthenticated
  rows <- store service (\db => queryRows db "UPDATE flux_auth_accounts SET attempts=CASE WHEN attempt_window <= clock_timestamp()-interval '1 minute' THEN 1 ELSE LEAST(attempts+1,11) END, attempt_window=CASE WHEN attempt_window <= clock_timestamp()-interval '1 minute' THEN clock_timestamp() ELSE attempt_window END WHERE id=$1 RETURNING password_hash,attempts <= 10 AS allowed" [Just session.account.id])
  [row] <- pure rows | _ => unauthenticated
  allowed <- textField row "allowed"
  True <- pure (allowed == "t")
    | False => do
      _ <- verifyPassword input.currentPassword service.dummy
      unauthenticated
  old <- textField row "password_hash"
  True <- verifyPassword input.currentPassword old | False => unauthenticated
  fresh <- hashPassword input.newPassword
  changed <- store service $ \db => withTransaction db $ do
    Right rows <- queryRows db "UPDATE flux_auth_accounts SET password_hash=$1,auth_version=auth_version+1 WHERE id=$2 AND password_hash=$3 AND EXISTS (SELECT 1 FROM flux_auth_sessions WHERE digest=$4 AND account_id=$2 AND expires_at > clock_timestamp()) RETURNING id" [Just fresh, Just session.account.id, Just old, Just session.digest]
      | Left err => pure (Left err)
    case rows of
      [_] => do
        Right _ <- execCommandPrepared db "DELETE FROM flux_auth_sessions WHERE account_id=$1" [Just session.account.id]
          | Left err => pure (Left err)
        pure (Right True)
      _ => pure (Right False)
  unless changed unauthenticated
  pure (JObject [("changed", toJSON True)])

passwordHandler : AuthService -> Handler
passwordHandler service ctx = do
  session <- requireSession service ctx.request
  rpcHandler (changePassword service session) (setHeader "Cache-Control" "no-store" ctx)

||| Install rpcErrorRenderer and HTTPS outside loopback. No permissive CORS or
||| cookie authentication is installed. These routes accept bearer headers only.
export
authRoutes : AuthService -> Router Handler
authRoutes service = empty
  |> post "/rpc/v1/auth/register" (\ctx => rpcHandler (register service) (setHeader "Cache-Control" "no-store" ctx))
  |> post "/rpc/v1/auth/login" (\ctx => rpcHandler (login service) (setHeader "Cache-Control" "no-store" ctx))
  |> post "/rpc/v1/auth/logout" (logoutHandler service False)
  |> post "/rpc/v1/auth/logoutall" (logoutHandler service True)
  |> post "/rpc/v1/auth/me" (meHandler service)
  |> post "/rpc/v1/auth/password" (passwordHandler service)
