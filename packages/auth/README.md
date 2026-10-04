# Flux Auth

Durable password accounts and revocable opaque bearer sessions for native Flux
servers. **This package is not application row authorization or a complete
production identity service.** The preview CRUD starter combines it with private
owner-scoped tasks and an Idris login UI; other applications must enforce their
own ownership rules.

## Requirements and integration

`flux-auth` depends on `flux-protocol` and `flux-db-flux`; it is forbidden in the
browser dependency closure. Build with a C11 compiler, pthreads, `make`,
`pkg-config` and libsodium **1.0.18+** (Argon2id). PostgreSQL also requires OpenSSL
3. On macOS: `brew install libsodium openssl@3 pkg-config`. On Debian/Ubuntu:
`apt-get install libsodium-dev libssl-dev pkg-config build-essential`.
Deployments must provide the corresponding shared libraries.

1. Append `MkMigration <nextVersion> "accounts and revocable sessions" authSchemaV1`
   to the application's reviewed migration list. `Flux.Auth.Schema.authSchemaV1`
   is frozen SQL, not an inferred schema plan. Never renumber or edit old migrations.
2. Create a bounded PostgreSQL pool with finite transport deadlines, then call
   `newAuthService pool lifetimeSeconds` once at startup. Lifetime must be **1 to
   2,592,000 seconds** (30 days). The CRUD app uses 86,400 seconds.
3. Mount `authRoutes service`, install `rpcErrorRenderer`, and pass
   `authenticator service` to generated protected routes. Combine routers explicitly:
   `MkRouter (accountRoutes.routes ++ protectedRoutes.routes)`.
4. The application owns/closes the pool. Startup creates a random dummy verifier;
   expensive request hashing runs on the runtime's owned blocking workers.

Use HTTPS outside loopback, `PGSSLMODE=verify-full` for remote PostgreSQL, and a
trusted CA bundle where needed. These endpoints do not install permissive CORS,
trust proxy headers, accept cookies, or infer identity from request JSON.
The dev proxy forwards exactly one bounded bearer header and no cookies, retaining
its host/origin/body checks. `./flux doctor` checks native prerequisites.

## HTTP contract

All routes are `POST /rpc/v1/auth/<name>`. JSON bodies are bounded to 64 KiB;
responses and errors have `Cache-Control: no-store`. Send the bearer only as
`Authorization: Bearer <token>`, never in a URL, cookie or owner field.

| Name | Body | Result |
| --- | --- | --- |
| `register` | `{"username":"new_user","password":"<password>"}` | `{"id":"<BIGINT>","username":"new_user"}` |
| `login` | Same credentials | `{"account":{"id":"...","username":"..."},"token":"...","expiresAt":"UTC ISO timestamp"}` |
| `me` | `{}` + bearer | Account object resolved from the session store |
| `logout` | `{}` + bearer | `{"loggedOut":true}`; revokes only that session |
| `logoutall` | `{}` + bearer | Same response; revokes all sessions for that account |
| `password` | `{"currentPassword":"...","newPassword":"..."}` + bearer | `{"changed":true}`; revokes all sessions atomically |

Register does not issue a session. Names contain 3–64 ASCII letters, digits,
hyphens or underscores and are canonicalized to lowercase. Duplicate names
return 409: registration intentionally reveals handle availability, so do not
use this endpoint as a promise of private email/account existence.

New passwords contain **15–256 Unicode characters**, without NUL; UTF-8 bytes
are hashed without trimming/normalization. Login accepts bounded nonempty input,
including incorrect short passwords, for normal verification failure. This is
not a breached-password screening service.

Missing, malformed, expired and revoked bearer credentials produce 401. A repeated
logout with the now-revoked token returns 401. Wrong-password and unknown-account
login failures use the same 401 envelope; unknown and rate-limited accounts run
a dummy Argon2id verification. Store/crypto failures produce redacted 500/503;
admission exhaustion produces 429. Account session-cap or stale-snapshot issuance
failures return 401 `Session unavailable`. Never treat an outage as authenticated.

## Security and resource policy

- libsodium Argon2id v1.3, **64 MiB / 3 passes / 1 lane**, with independent random
  salts. Only this bounded encoded policy is accepted; hostile/corrupt work
  factors fail before hashing. No password is sent to PostgreSQL.
- **Two admitted hash jobs and no additional hash queue**, at most **60 starts per
  minute per OS process**. Reservations happen before scheduling on the bounded
  runtime worker pool (the rate window is fixed, not sliding). Password changes
  consume two jobs sequentially. Queue
  failure/cancellation uses bracketed cleanup; native work is joined, not abandoned.
  CPU work is not forcibly preempted: fixed costs bound it, not a fake timeout.
- **Ten password-check attempts per minute per account**, including successful
  logins and password changes, updated atomically using the database clock.
  The window survives application/database restart. Process-wide admission resets
  on process restart; it is not a distributed/per-IP anti-abuse service. Put a
  trusted edge/cluster rate limiter in front of public deployments.
- Sessions contain **256 bits of OS-backed randomness**, encoded as 43 base64url
  characters without padding. Only SHA-256 token digests, owner IDs and database
  timestamps are stored. Tokens are returned once; possession grants access.
  Expiry is checked against the DB clock on every protected request.
- At most **32 stored sessions per account**; expired rows are reclaimed for that
  account during issuance. Logout removes rows durably. Logout-all and password
  change advance an account version and delete sessions in the same transaction.
  Issuance locks/rechecks its password/version snapshot, so an old-password login
  racing a password change cannot leave a valid session behind.
- Already-admitted domain requests may finish during revocation. Owner-scoped
  transactions must define any stronger serialization requirement; this library
  does not retroactively cancel arbitrary application writes.
- Auth storage intentionally does **not** use `dbFail`, which can log raw PG error
  detail. Neither raw credentials, hashes nor token digests are emitted in its
  errors/logs. Reverse proxies/application instrumentation must follow the same
  redaction policy. Native buffers are wiped on release; managed Idris strings
  cannot be promised deterministic erasure. Do not log/serialize request objects.

No MFA, OAuth/OIDC, email verification, password recovery or persistent browser
credential storage is supplied. The starter has a handwritten Idris login UI
using portable `Iris.Client.Auth` commands. Its native RPC transport is
now in-process verified libcurl, with no credential argv or temporary request
files. The legacy generic `Iris.Effect.Http` shell transport remains unsuitable
for credentials. Browser clients use same-origin fetch and memory-only tokens,
not localStorage/sessionStorage/cookies.

## Migration and verification

The CRUD app appends identity as migration 2; migration 1 and anonymous `todos`
rows remain untouched by identity migration 2. The starter's separate migration
3 archives anonymous rows without adoption and creates an owner-constrained task
table; see [the reviewed cutover](../../platform/crud/OWNERSHIP_MIGRATION.md).
These auth-package fixtures intentionally continue testing the frozen v1/v2 slice.

From the workspace root:

```sh
# pack ignores C-only changes unless the manifest/source timestamp is refreshed.
touch packages/auth/flux-auth.ipkg
pack --no-prompt install flux-auth
pack --no-prompt build packages/auth/test/test.ipkg
bash packages/auth/test/native.sh
python3 packages/auth/test/integration.py
python3 tools/workspace.py test
```

The integration suite owns its PostgreSQL 16 container and temporary TLS CA. It
checks reviewed v1 upgrade/history/data preservation, salted hashes, digest-only
sessions, two real Chromium contexts, generated principal enforcement, server/DB
restart persistence, expiry, scoped/all-session logout, password-change and
concurrent issuance revocation, durable attempt windows, session caps, bounded
hashing/owner-loop responsiveness, hostile costs, DB outage fail-closed behavior
and credential-free logs. Native ASan/UBSan tests also check admission/release and
rate budgets. Fresh-copy CLI browser acceptance exercises the actual application
account routes through the dev proxy. Tests never point at an existing database.
