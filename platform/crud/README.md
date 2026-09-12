# Flux Todo — generated-client Flux UI application

This is a complete **public todo demo**, not an authenticated production app.
`TodoUI.idr` owns the model/update/view; `MainWeb.idr` runs Flux UI's DOM backend.
Every API operation goes through generated `Client.idr` commands. There is no
handwritten JavaScript business model or parallel fetch client in the app.

The UI supports create, fetch/edit, save/cancel, toggle, confirmed deletion,
keyset pagination, loading/empty states, validation, typed failures and explicit
retry. BIGINT IDs stay strings. Writes are serialized while pending, input is
retained on failure, and mutation requests are never automatically retried.
Flux UI lifecycle suspension cancels pending effects; the UI clears its pending
state, preserves the draft and recovers on resume without replaying a write.
Transport failure can mean a write committed without its response arriving:
refresh before retrying. This API does not yet offer idempotency keys or
optimistic concurrency/version checks.

## Run from the Flux root

Requires pack, Node 20+, Python 3, curl and Docker for disposable PostgreSQL.

```sh
./flux doctor
./flux build
./flux dev --disposable-db --no-build
# Open http://127.0.0.1:8090; Ctrl-C shuts down the API and removes this DB.
```

**Disposable data is removed on normal, successful cleanup.** If Docker removal
fails or times out, the CLI exits unsuccessfully and reports the container name,
Docker diagnostic and removal command; data may remain until cleanup succeeds.
No existing database or application data is reset. To retain data, supply all of
`PGHOST`, `PGPORT`, `PGUSER`, `PGPASSWORD`, `PGDATABASE` for a dedicated database,
then use `./flux dev --no-build` without the disposable flag. For a remote test
database set `PGSSLMODE=verify-full` and optionally `PGSSLROOTCERT=/path/to/ca.pem`
(otherwise OpenSSL system trust is used). Host/IP SAN verification is mandatory;
weaker libpq modes and CA/plaintext conflicts fail closed. The app still has public
endpoints: do not deploy private/multi-user data yet. Do not commit secrets.

The CLI serves only the HTML, stylesheet and compiled JS, proxying `/rpc/v1/`
to the loopback API. Source, configuration and other repository files are not
served. The page uses same-origin requests and a strict CSP without inline
scripts/styles. The proxy rejects cross-origin writes and bounds bodies and
responses. It is **development tooling**, not a deployment server; the demo API
itself remains public with development CORS. Do not expose it to untrusted users.

## Project CLI

```sh
./flux new shopping
./flux --project apps/shopping generate
./flux --project apps/shopping generate --check
./flux --project apps/shopping build
./flux --project apps/shopping dev --disposable-db --no-build --port 8091
# Against explicitly configured PG*, after building:
./flux --project apps/shopping migrate
```

`new` copies the reviewed todo starter into a new `apps/<name>` directory,
generates its protocol/client, and registers both package IDs and the browser
boundary root in the single workspace map. It refuses existing destinations,
invalid names, escaping paths and package collisions. Commit the new app,
`workspace.json` and `pack.toml` together. Creation is serialized and restores
its own map updates on ordinary errors; an interrupted/power-lost two-file map
update is detectable with `workspace.py check`; restore the desired manifest
and run `sync` to recover the package map.

`flux.json` identifies the schema and server/UI package manifests. `build`
requires current generated files; run `generate` after schema changes and
adapt the handwritten server/UI if the generated types change. The starter
uses the existing pooled todo repository; it is not arbitrary model-to-SQL
scaffolding. `migrate` applies the same explicit frozen SQL/history checks as
startup and exits without opening an HTTP listener. It does not plan, roll back
or automatically derive destructive schema changes.

`dev` builds once unless `--no-build` is given. It has no file watcher/hot reload;
rebuild and restart after source changes. `--port 0` selects an available UI
port and prints the URL. Both API and UI bind loopback. Subprocesses have bounded
waits and owned process-group cleanup; SIGINT/SIGTERM initiates clean shutdown.

This CLI is repository-local (`./flux`), for macOS/Linux workspaces, not a
published globally installed command or a standalone SDK project generator.
Authenticated PostgreSQL TLS is available; deployment, user identity and row
authorization remain separate milestones.

## Verification

Install browser test dependencies once:

```sh
(cd packages/ui && npm ci && npx playwright install chromium)
python3 platform/test_app.py
# All platform gates, also run by root CI:
python3 tools/workspace.py test
```

The application test copies source without build/node/Git artifacts into a
fresh workspace, creates an app through the CLI, builds it, applies migrations
twice, then operates the **real UI** in Chromium. It verifies CRUD, validation,
errors/retry, cancellation of edits/deletes, lifecycle interruption after a
committed write with a withheld response, missing rows, pagination, exact
BIGINT IDs, safe text rendering, narrow layout, persistence after reload and
restart, restricted static serving and cross-origin/body-limit rejection.
PostgreSQL is checked independently; a separate disposable CLI session must
remove its own database without changing the configured test database.
