# Flux consolidation verification

The six versioned components listed in `workspace.json` were imported as
unsquashed subtrees. `git merge-base --is-ancestor <source-tip> HEAD` succeeded
for all six recorded tips. Original repositories remained clean and unchanged.
The unversioned Docker helper's source was copied without build outputs.

## Clean-source integration

An index export (`git checkout-index`) was created outside the old workspace at
`/tmp/flux-consolidation-final`, with no Git metadata, node_modules or compiler
build artifacts copied in. Browser dependencies were installed from the included
UI package lock. The canonical map pointed all 19 local package entries inside
that export; no old sibling source paths were used by the workspace map.

`python3 tools/workspace.py test` passed all **16 recorded steps**:

- Seven workspace unit checks, including transitive browser/server boundary
  rejection and subprocess cleanup.
- Eighteen generator tests and current-output checks for both schemas.
- Flux regression build and executable.
- Native Iris client, server, migration and CRUD example builds.
- JS Iris client builds.
- Native/Node/Chromium wire, error, cancellation and CORS tests.
- Pooled PostgreSQL integration plus the 14 migration checks.
- Complete CRUD, pagination, independent DB verification and safe restart tests.

`results.json` records command arguments, durations and exit codes; every exit
is zero. `driver.log` is the combined runner output. Explicit failure-marker
scanning also passed (expected browser console HTTP-error diagnostics during
negative probes are not failed assertions).

Additionally, the imported runtime/service/stream/socket suites, native runtime
ASan/UBSan checks, and an independent `packages/db` build passed from that same
export. Their logs are included here. This verification ran on macOS arm64;
it is not a fresh Linux, mobile, TUI or full UI-component test run.

The initial export attempt found that pack can clean the root build directory,
which also removed the runner's reports. The runner now stores reports under
`.workspace/reports/`; a subsequent clean export passed, followed by a complete
rerun after adding interruption-safe process-group cleanup. No test criteria
or platform deadlines were relaxed.

## Boundaries

This establishes source/workspace consolidation and the selected integration
gate, not production readiness, renamed public APIs or universal feature parity.
Authenticated PG TLS, identity/authorization, the full application CLI/UI workflow,
and production deployment remain outstanding. Original pre-consolidation reports
are retained separately as historical evidence.
