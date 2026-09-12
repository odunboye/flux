# Identity and private tasks: staged implementation

Status: **endpoint enforcement, durable accounts and revocable sessions are
implemented. Private task ownership and login UI are still pending.** Do not
deploy the public task demonstration with private data. Authenticated PostgreSQL TLS is available and must be enabled
for remote databases; it does not secure the HTTP connection or authorize users.

## Implemented boundary

A schema endpoint with `access: "authenticated"` generates a principal-bearing
callback. Its router cannot be constructed without an `Authenticator` supplied
by server application code. The adapter resolves identity before decoding JSON
or executing a domain callback. Missing/invalid/revoked sessions must resolve to
`Nothing`; resolver infrastructure failures throw and receive redacted errors.
No caller-provided owner field becomes a principal.

Protected responses and RPC errors carry `Cache-Control: no-store`. Duplicate
Authorization fields are rejected by the HTTP parser, including differently
cased duplicates. OpenAPI marks protected methods with bearer security; public
methods remain explicitly public. The framework never chooses permissive CORS
for an authenticated application.

`platform/auth-boundary/` is a loopback-only test fixture with literal credentials,
not a token verifier or deployable authentication service. Real HTTP tests cover
missing/invalid credentials, authentication before malformed-body decoding,
principal isolation from a claimed owner, resolver failure redaction, duplicate
credentials, mixed public/protected routes and bounded clean shutdown.

## Implementation slices

1. **Password and token primitives — implemented in `flux-auth`.** libsodium
   Argon2id uses 64 MiB, three passes, random salts and bounded work-factor
   validation. Two admitted hash jobs, no extra hash queue, 60 starts/minute/process;
   owned blocking workers join on cancellation and wipe native buffers. Passwords
   are 15–256 characters. Unknown/locked accounts use a random dummy verifier.
2. **Durable accounts and sessions — implemented.** Reviewed identity migration 2
   leaves original task migration/history/data unchanged. Canonical unique handles,
   random 256-bit tokens stored only as digests, DB-clock expiry, indexed lookup,
   current/all-session logout and atomic password-change revocation. Issuance
   locks/rechecks its password/version snapshot to prevent stale-login races.
   Ten attempts/minute/account survive restart; at most 32 sessions/account.
   Auth storage errors are redacted without logging raw PG detail. Real HTTP,
   PostgreSQL/TLS, two Chromium contexts, restart, revocation, expiry, concurrency,
   rate/cost limits and fail-closed outage tests are implemented. The real CRUD
   app and fresh-copy CLI expose these APIs; see `packages/auth/README.md`.
3. **Private repository and migration — pending.** Keep migration 1's SQL/checksum frozen.
   Preserve existing anonymous rows in an explicitly named legacy archive, not
   under the first account to register. A reviewed transactional migration will
   create the ownership-constrained task table and its `(owner_id, id)` index.
   No public endpoint may read the archive. Adoption into an account requires an
   explicit operator-reviewed operation; no silent assignment, deletion or replay.
   Every get/list/create/update/toggle/delete statement derives ownership from
   the verified principal. Updates/deletes constrain owner and ID in the same SQL
   statement, not a separate check-then-write. Pagination always includes owner
   scope, including lookahead and direct forged cursors. A foreign owner's ID
   has the same response as a nonexistent ID.
4. **Client/UI cutover — pending.** Add registration/login/logout and session expiry UX,
   then switch every Todo endpoint to authenticated access together with its
   owner-scoped handler. Do not temporarily protect only the UI. Bearer tokens
   remain out of URLs and persistent browser storage; browser reload may require
   login again in the first slice. Clear all task state on identity changes.
   Tag callbacks with a session generation so late responses from user A cannot
   enter user B's model. Preserve lifecycle cancellation and never replay writes
   automatically. The same-origin dev proxy now forwards exactly one bounded
   bearer credential without weakening its origin/host/body checks. Native transports
   must not expose credentials in subprocess arguments or diagnostic output.

## Required acceptance before calling the application multi-user

- Real PostgreSQL plus two independent browser contexts; register/login, restart
  server and database, authenticate existing accounts and recover owned tasks.
- User A cannot get/list/change/toggle/delete B's task, including pagination,
  forged owner JSON, direct IDs, stale callbacks and concurrent requests.
- Expired, revoked, malformed and missing tokens rejected; logout/re-login does
  not leak the previous user's tasks. Document that already-admitted requests
  can finish unless session checks are serialized with their transaction.
- Fresh migration and populated version-1 upgrade preserve anonymous rows and
  migration history; restart causes no replay or accidental ownership adoption.
- Bound authentication CPU/memory/queue occupancy and deadlines under contention;
  errors and instrumentation never contain passwords or tokens.
- Verify complete native/generated/browser behavior, not only mock principals.
  Require HTTPS outside loopback and authenticated PostgreSQL TLS remotely.
  Hosted Linux evidence remains distinct from local Linux-container results.
