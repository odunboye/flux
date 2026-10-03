# Private tasks, session-safe login UI and native RPC credentials

Verified 2026-09-12 on macOS 26.6.2 / Apple Silicon, pinned Idris2
`74b33730b6fea649b15e8d01ab099df9effcc7a0`, pack collection `nightly-260903`.
The complete **37/37 workspace gate passed**; `results.json` records commands,
exit codes and timings. Source run: `.workspace/reports/20260912-170831/`.

## Acceptance evidence

- `flux-ui-crud.log`: real PostgreSQL, populated v2→v3 upgrade preserving complete
  v1/v2 history, account and session; anonymous table archived without adoption.
  Old binaries reject future migration history. All six task routes reject
  missing/invalid credentials. Forged owners are ignored; foreign IDs match
  nonexistent IDs across get/update/toggle/delete. Concurrent scoped mutations,
  private-content-bearing PG error redaction and atomic failure are verified.
- Node and Chromium generated clients each complete 24 concurrent CRUD lifecycles
  over exact BIGINT string IDs and private 50-row pages. Native Idris performs
  real account login, private reads/create/delete, logout and revoked access.
  Interleaved owners exercise 50/1 pagination and forged foreign cursors.
  Server **and PostgreSQL restart** preserve private data, archive/history and
  sessions; DB-clock expiry and logout-all reject every task method.
- `flux-ui-app-cli.log`: a source-only workspace copy creates/builds/migrates/runs
  a real application through `./flux`. Chromium tests use the actual Idris DOM
  model, login/register/logout forms, masked/cleared passwords and memory-only
  bearers. Two contexts verify isolation. Genuine user-A reads and committed-write
  acknowledgements are deliberately delivered after user B logs in; neither
  changes B's rows/draft. Failed logout clears local data immediately and requires
  an explicit revocation retry. Revocation clears the UI on 401. Existing CRUD,
  lifecycle interruption/no-write-replay, layout, pagination, storage persistence
  and owned disposable cleanup checks remain passing.
- `client-native-security.log`: ASan/UBSan against the actual in-process libcurl
  bridge. Headers/password body arrive without appearing in process arguments or
  temporary request files. Ambient proxies and redirects are not used; URL
  credentials/query/fragment, remote plaintext and CA/plaintext conflicts reject.
  Trusted TLS succeeds; untrusted and wrong-host TLS send no HTTP credentials.
  Oversized, NUL and six malformed UTF-8 responses reject. A genuinely delayed
  peer exercises the 30-second request timeout.
- `linux-native-http.log`, `linux-packages.log`: the same C bridge/sanitizer checks
  passed in a **local Debian 12 aarch64 container**, GCC 12 and libcurl 7.88.1.
  This is not hosted Linux CI or a full Linux Idris/browser run.
- `ui-tests.log`: all seven UI suites pass, including new DOM password semantics,
  terminal masking and shared canvas/terminal mask checks. `ui-browser.log`:
  3/3 existing browser suites pass. Full tool/generator runs: 29 and 19 tests.
  `doctor.log` includes the new libcurl development prerequisite check.
- The remaining workspace logs retain runtime, authenticated PG TLS, durable
  auth, protected-boundary, wire/migration and landing regressions.

## Scope and limitations

The canonical starter is now a private multi-user **development preview**. Legacy
`apps/todo-api` and protocol smoke fixtures remain public test examples. Migration
3 has no adoption/deletion API; follow `platform/crud/OWNERSHIP_MIGRATION.md`.

Native RPC uses libcurl, not the legacy generic UI shell HTTP effect (which is
still unsuitable for credentials). Native Tasks remain synchronous; libcurl's
5s connect/30s total settings are network deadlines, not hard real-time preemption
of platform DNS/trust operations. No application request worker is detached.
Managed/library copies cannot promise deterministic secret erasure.

Browser reload requires login. Expiry/revocation clears cached UI state when a
request returns 401, not via an idle expiry timer. Already admitted server writes
may finish during revocation. Logout failure/page closure can leave a server
session alive until explicit revocation/expiry; no write is automatically replayed.

Production HTTPS/deployment, distributed anti-abuse, backup/restore, broader
identity services, hosted Linux confirmation and native mobile certification
remain separate work. No push was performed.
