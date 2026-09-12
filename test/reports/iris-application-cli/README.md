# Iris application and initial project CLI verification

`python3 tools/workspace.py test` passed all **19 steps** on macOS arm64.
`results.json` records the commands, durations and zero exit codes. Explicit
failure-marker scanning passed. Existing imported-code compiler warnings remain
visible; no test criteria, authentication checks or platform deadlines were
relaxed. ShellCheck and actionlint 1.7.7 also passed for the CLI/CI changes.

The gate includes ten workspace tests, seven CLI tests, eighteen generator tests,
both schema freshness checks, Flux regressions, native/JS builds, previous
wire/PG/migration/CRUD integration, and the new actual-application acceptance.

## Actual application acceptance (`iris-app-cli.log`)

A new temporary workspace was copied without Git metadata, node_modules,
compiler outputs or generated mobile JS. Using its repository-local `./flux`:

1. `new acceptance` generated and registered a reviewed starter (21 existing
   package entries became 23 inside the temporary workspace).
2. `generate --check` and `build` succeeded with workspace-contained dependencies.
3. `migrate` ran twice against an isolated database; exactly one history row
   remained, with no HTTP listener started by the migration command.
4. `dev` served the real compiled Iris UI and proxied generated RPC commands.
5. Chromium exercised loading/empty/validation states, duplicate-write
   suppression while busy, Unicode/literal HTML rendering, fetch/edit/save,
   edit cancellation, typed rejection with retained input and explicit retry,
   toggle, delete confirmation/cancellation, a concurrently missing row,
   transport failure/recovery and reload persistence.
6. A real create committed while its acknowledgement was withheld. Lifecycle
   pause cancelled the pending effect; resume retained the draft and restored
   interaction without replaying the write. Refresh discovered the committed
   row, which was then explicitly deleted through the UI.
7. After restart and 55 additional SQL seeds, the UI loaded 50/6 keyset pages,
   retained rows on a failed continuation, retried, and showed 56 distinct exact
   BIGINT IDs. The narrow viewport did not overflow.
8. Direct probes confirmed source/config paths are not served, cross-origin
   writes are denied by the dev proxy and oversized bodies are rejected.
9. Independent PostgreSQL queries verified the UI-created/completed row,
   total row counts and unchanged migration history. CLI shutdown was clean.
10. A separate `dev --disposable-db` session started with an empty owned database,
    removed it on exit and left the configured 56-row database unchanged.

Temporary applications/maps and all test-owned databases were removed. No
original application data or companion source repository was modified.

## Scope

This is a complete **todo browser UI** and an initial macOS/Linux **workspace
CLI**, not universal UI parity or a production platform. Standalone SDK/CLI
packaging, watch/reload, schema-change planning, deployment, authenticated PG
TLS, identity and row authorization remain outstanding.

Root CI now includes these checks, but the first GitHub-hosted Linux run and
required-check branch protection remain external confirmations. This report is
local macOS evidence, not a completed remote CI run.
