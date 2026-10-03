# Flux DB breaking rename verification

Local **macOS ARM64** verification with the pinned Idris2 0.8.0 compiler
(`74b33730b6fea649b15e8d01ab099df9effcc7a0`) and Node 26.8.1. These are not
hosted Linux CI results.

## Changes

- `flux-db` / `flux-db-flux` 0.3 replace the old packages outright.
- All 12 persistence/integration implementation modules own `Flux.DB.*`
  namespaces. Old `Nebula.*`, DB-owned `Data.PG*`, `Derive.PGActiveRecord`, and
  standalone `ObjectFromJSON` module paths have no aliases.
- Consumers, CLI templates, tests, canonical package maps, browser
  boundaries, documentation and landing-page branding use the new names.
- Metadata is `flux_db_meta.migrations`. Legacy-schema presence fails closed;
  explicit operator cutover preserves history rather than replaying it. The
  advisory-lock identity, checksums and application SQL/schema remain intact.

## Verified

- **24/24 workspace steps** passed (`workspace/results.json`), including actual
  landing/Chromium, generated native/Node/browser clients, fresh-project CLI,
  CRUD, interruption/persistence and disposable database isolation.
- The complete persistence derivation/query/repository suite now runs inside
  the owned PostgreSQL fixture used by the root platform gate.
- **21 migration checks** passed: old checks plus no-side-effect batch rejection,
  legacy/both-schema refusal, no parallel history creation, complete history
  preservation, no historical replay, and successful post-cutover migration.
- **26 tool tests**, **18 generator tests**, and the complete UI suite passed.
  UI evidence includes seven native suites, Node API verification, both TUI
  entry points/renamed C FFI and three Chromium tests.
- ShellCheck, actionlint 1.7.7 and whitespace checks passed locally.
- Original import records are unchanged and all six original tips remain
  ancestors. Saved historical reports and unrelated untracked work are intact.

## Additional migration safety correction

The new post-cutover test exposed an existing bug: the old zero-parameter
`execCommand` path could execute an SQL batch containing `COMMIT` before its
result-count check rejected it. The new additive `execCommandPrepared` API
always uses PostgreSQL Parse/Bind/Execute; migration commands now use it.
The regression verifies no statements from a rejected batch execute, while a
quoted semicolon and single trailing semicolon still work. Existing
`execCommand` callers retain their previous behavior; this is not a blanket SQL
sandbox or a general transport rewrite. No test deadlines were increased.

## Reproduce

```sh
python3 tools/workspace.py check
python3 tools/workspace.py test
CI=1 bash tools/ci-suite.sh ui
```

Docker with `postgres:16` and installed Chromium/browser dependencies are
required. Read [the mandatory existing-database cutover guide](../../../packages/db/MIGRATION.md)
before deploying to a pre-rename database. Authentication, authorization and
verified PostgreSQL TLS remain separate production work.
