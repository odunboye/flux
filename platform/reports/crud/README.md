# Typed Iris CRUD verification

Baseline: Flux `f64aef7`, Nebula `a177aee`.

Verified locally on macOS with native Idris servers, JS/Node fetch, real
Chromium, and disposable PostgreSQL 16 containers:

- `generator.log`: all 18 tests pass, including named-model ordering,
  list/nullability schema generation, cycles, ambiguity and depth rejection.
- `build.log`: CRUD server/client and prior Iris/Flux examples build.
- `integration.log`: Node and Chromium each complete 24 concurrent seven-request
  CRUD lifecycles (336 lifecycle HTTP requests total, plus validation/pagination
  probes). Tests cover exact text BIGINT IDs, nested lists, nullable records,
  malformed IDs/titles/cursors, missing records, 50-row pagination over 55
  seeds, independent database checks, migration bootstrap and safe restart.
- `previous-wire-regression.log`: existing native Iris, Node and Chromium
  one-method protocol/error/cancellation/CORS checks pass.
- `previous-pg-regression.log`: previous 14 migration checks and generated Iris
  pooled-create tests pass; PostgreSQL confirms 50 created rows.
- `flux-regression.log`: full existing Flux regression suite passes.

Build and reproduction commands are in `../../README.md`. Generated-output
checks pass for both `example/schema.json` and `crud/schema.json`.

Limits: these are correctness/integration checks, not a load benchmark or
native Linux verification of this new feature. The UI is not implemented;
this exercises Iris commands and transports directly. Endpoints are public.
Authentication and authenticated PostgreSQL TLS remain outstanding. Browser
console 400/415/500 messages during intentional negative probes are expected;
the test assertions verify that those responses remain typed and readable.
