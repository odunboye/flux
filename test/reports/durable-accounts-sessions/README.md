# Durable accounts and revocable sessions — 2026-09-12

## Implemented

New server-only `flux-auth` package: libsodium Argon2id (64 MiB, three passes),
bounded hashing admission on owned blocking workers, canonical unique accounts,
256-bit opaque sessions stored only as digests, DB-clock expiry, current/all-session
logout and password changes with atomic revocation. Issuance locks/rechecks an
account password/version snapshot. Unsupported stored hash costs fail before
expensive work; native buffers are wiped when ownership ends. Auth errors never
log raw PostgreSQL details.

The actual CRUD application and generated project template expose
`/rpc/v1/auth/{register,login,me,logout,logoutall,password}`. Migration 2 adds identity
without changing frozen migration 1 or anonymous tasks. Only the legacy public
Todo methods retain wildcard CORS. The same-origin dev proxy forwards one bounded
bearer header, never cookies, and rejects duplicate/malformed credentials without
weakening origin/host/body checks. Doctor/CI check/install native dependencies.
The canonical workspace now contains **23 packages** and forbids Auth in browsers.

## Verification

- **34/34** combined integration steps on local macOS ARM64, pinned pack Idris
  compiler. Existing PostgreSQL/TLS, migration, native/generated/browser, CRUD,
  fresh-copy CLI and landing regressions pass.
- Real owned PostgreSQL 16 with verified TLS: v1 upgrade preserves anonymous data,
  exact full v1 history and checksums; Argon2id hashes have independent salts;
  sessions store only SHA-256 digests. Accounts and existing sessions survive
  application and PostgreSQL restarts.
- Two real Chromium contexts register/login, obtain their own server-resolved
  principal, and exercise scoped logout. No cookies/localStorage/sessionStorage
  are used and account responses have no wildcard CORS. Fresh-copy CLI acceptance
  separately exercises real account APIs and revocation through the dev proxy.
- Missing/malformed/expired/revoked credentials fail. Spoofed JSON/cookies do not
  authenticate. Wrong and unknown accounts return the same login failure. Even
  no-argument authenticated routes enforce bounded JSON/media validation before
  mutations. Password changes revoke multiple sessions; three concurrent
  old-password login races leave no surviving session.
- Durable ten-attempt account windows survive restart. Concurrent issuance cannot
  exceed 32 sessions/account; concurrent duplicate registration yields one account.
  Eight concurrent hashing requests hit admission limits while the owner loop
  remains responsive. Actual one-second expiry is tested without enlarging
  deadlines. Hostile Argon work factors and missing session storage fail closed.
  A DB trigger deliberately raises a secret/hash-bearing exception; neither
  that detail nor credentials appear in server logs or public errors.
- **29 tool tests**, **19 generator tests**, native crypto ASan/UBSan tests,
  ShellCheck, workspace closure and whitespace checks pass.
- Local Docker **Linux aarch64 / Debian 12 / libsodium 1.0.18**: strict native
  bridge build and ASan/UBSan crypto/admission/rate-budget tests pass. This is
  **C bridge evidence, not a Linux Idris/HTTP/database/browser run**. Hosted Linux
  confirmation remains pending; platform CI now installs libsodium development
  files and runs the complete gate.

Full source evidence: `.workspace/reports/20260912-154538/`. Selected logs/results
are copied here. All databases, certificates and private keys were disposable;
container/volume removal is checked. A readiness race found during regression was
fixed by waiting on PostgreSQL TCP rather than its temporary initialization-only
Unix socket. No application/test deadline was increased.

## Scope and operating limits

The account/session milestone is implemented, **not the private multi-user task
application**. Todo methods remain public with a visible warning. Task ownership,
login UI, session-generation-safe UI state and explicit legacy task adoption remain
next. Existing native Flux UI curl/temp-file transport is not credential-safe;
do not use it for account credentials until upgraded. Browser/API flows are the
verified credential path here.

Hash costs are fixed, with two admitted jobs, no extra hash queue and a per-process
60-start window. Account windows are durable but process limits are not a distributed
anti-abuse service. Production needs HTTPS, verified remote PG TLS, appropriate
edge/cluster limits and secret-safe instrumentation. Native hashing is joined, not
forcibly preempted; already-admitted domain requests may finish during revocation.
No MFA, recovery, email verification, deployment or backup/restore is supplied.

See `packages/auth/README.md` for the API, dependencies, precise limits, migration
contract and reproduction commands. No push or hosted-CI completion is claimed.
