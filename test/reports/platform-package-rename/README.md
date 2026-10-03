# Coordinated platform package rename verification

Local **macOS ARM64** results, using the pinned Idris2 0.8.0 compiler
(`74b33730b6fea649b15e8d01ab099df9effcc7a0`) and Node 26.8.1. These are not
hosted Linux CI results, including the runtime log from `linux_runtime.sh`:
that portable script was executed on macOS for this check.

## Scope and coordination

Six package identities changed together: `flux-runtime`, `flux-client`,
`flux-protocol`, `flux-postgres`, `flux-postgres-pool`, and `flux-docker`.
Related test package/executable prefixes and consumers were updated. No old
package aliases remain; existing suitable module namespaces and implementations
are retained, not replaced by wrappers. SQL metadata, checksums, RPC schemas,
environment contracts and native ABI symbols are unchanged by this batch.

Disjoint source-file updates ran in parallel workers, with shared manifest and
provenance handling centralized. Unit/generator/lint checks ran alongside the
integration lane. All pack compiler/build/install operations were serialized
against the shared workspace/cache.

## Results

- **25/25 integration steps passed** (`workspace/results.json`), including
  naming/boundary checks, actual landing/Chromium checks, generated native/Node/
  browser clients, PostgreSQL persistence/migrations/pooling, CRUD, and fresh-copy
  project creation/build/migration/browser use and disposable database isolation.
- **28 tool tests** and **18 generator tests** passed.
- Direct renamed PostgreSQL unit and property executables passed
  (`pg-unit.log`, `pg-prop.log`).
- Runtime task, service, stream and socket checks passed (`runtime.log`), including
  ownership, cancellation, cleanup, byte-exact transfer and backpressure.
- The full UI suite passed: native/Node public API, both native TUI entry points,
  release checks and three real Chromium tests (`ui.log`).
- The direct pool and Docker test packages compiled with their renamed package
  dependencies and executable names (`pool-build.log`, `docker-build.log`). Their
  standalone executables were **not run**: they assume a fixed database endpoint
  or fixed Docker container/port. Pooled PostgreSQL behavior was exercised by the
  owned disposable-database integration gate instead.
- ShellCheck, actionlint 1.7.7, canonical-map validation and whitespace checks
  passed locally.
- Original versioned/unversioned import records are unchanged; all six imported
  source tips remain ancestors. Original sibling repositories, historical reports
  and unrelated untracked work were preserved.

## Reproduce

```sh
python3 tools/workspace.py check
python3 tools/workspace.py test
CI=1 bash tools/ci-suite.sh ui
bash packages/runtime/test/linux_runtime.sh
```

Run compiler lanes sequentially. Docker/PostgreSQL and installed Chromium/Node
browser dependencies are required for integration. See the
[package migration guide](../../../design/PACKAGE_MIGRATION.md) for exact package
paths and retained namespaces. No further database cutover is introduced here;
the earlier Flux DB cutover remains required for pre-Flux-DB databases.
