# Authenticated endpoint boundary — 2026-09-12

First slice of the accounts/session/ownership milestone, **not completion of it**.

Implemented generated `authenticated` access with a mandatory server resolver
and principal-bearing callbacks. Missing credentials reject before JSON parsing;
resolver errors remain redacted. Protected responses and errors are not cacheable.
The HTTP parser rejects duplicate Authorization fields rather than choosing one.
Unknown access modes still fail generation. Public-only generated artifacts remain
unchanged; mixed schemas preserve explicit public and protected routes. OpenAPI
marks protected methods with bearer security without exposing principals as wire
models.

Verified on local macOS ARM64 using the pinned Idris compiler:

- **30/30** combined workspace integration steps, including existing real
  PostgreSQL/TLS, generated native/browser clients, CRUD, migrations and fresh-copy
  CLI acceptance.
- **19 generator tests**, including mandatory resolver/callback types, matching
  OpenAPI, browser dependency isolation and rejection of unknown access policies.
- Compiled generated mixed-access server exercised over real HTTP: anonymous and
  invalid credentials; authentication before malformed JSON; two resolved test
  identities overriding a claimed owner; normal 400/415 validation; resolver 500
  redaction; no-store headers; case-insensitive duplicate Authorization rejection;
  public route and preflight behavior; bounded clean server shutdown.

The fixture credentials are literal, loopback-test-only values. These tests do
**not** establish durable accounts, password security, session expiry/revocation,
owner-scoped persistence, authenticated browser login or production readiness.
Existing Todo endpoints remain public. No new hosted Linux evidence is claimed.

Source logs: `.workspace/reports/20260912-142344/`. Reproduce with
`python3 tools/workspace.py test`. The staged implementation and explicit policy
for preserving anonymous legacy tasks are in `design/IDENTITY_IMPLEMENTATION.md`.
