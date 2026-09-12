module Flux.Auth.Schema

%default total

||| Frozen reviewed SQL. Embed as ONE new migration in the application's existing
||| history, without renumbering or editing older migrations. No task data changes.
public export
authSchemaV1 : List String
authSchemaV1 =
  [ "CREATE TABLE flux_auth_accounts (id BIGSERIAL PRIMARY KEY, username TEXT NOT NULL UNIQUE CHECK (username ~ '^[a-z0-9_-]{3,64}$'), password_hash TEXT NOT NULL CHECK (length(password_hash) < 128), auth_version BIGINT NOT NULL DEFAULT 0, attempt_window TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(), attempts INTEGER NOT NULL DEFAULT 0, created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp())"
  , "CREATE TABLE flux_auth_sessions (digest TEXT PRIMARY KEY CHECK (digest ~ '^[0-9a-f]{64}$'), account_id BIGINT NOT NULL REFERENCES flux_auth_accounts(id) ON DELETE CASCADE, created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(), expires_at TIMESTAMPTZ NOT NULL, CHECK (expires_at > created_at))"
  , "CREATE INDEX flux_auth_sessions_account ON flux_auth_sessions (account_id)"
  , "CREATE INDEX flux_auth_sessions_expiry ON flux_auth_sessions (expires_at)"
  ]
