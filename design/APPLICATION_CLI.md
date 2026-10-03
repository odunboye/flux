# Flux application CLI

Flux's Python CLI supports applications outside this checkout. Application layout,
dependency maps, generation, asset staging, watch/HMR policy and native execution
are framework features; an app does not need a Python launcher.

## Install and select an application

```sh
# From the Flux checkout (macOS/Linux, Python 3.10+, pack/native prerequisites):
./flux install-cli
# If another command named flux already exists, inspect it first. To replace it
# with a reversible backup, explicitly use: ./flux install-cli --force
# Ensure ~/.local/bin is on PATH; restart the shell or run hash -r if necessary.

cd /path/to/application
flux sync
flux generate
flux check
flux build
flux dev --hot --disposable-db
flux run --disposable-db
```

The installed shell shim selects this checkout, not a downloaded SDK. It must stay
at that location; reinstall after moving it. Use `--bin-dir <directory>` to choose
a different PATH directory. Existing commands are never replaced without `--force`;
replacement first renames the previous launcher to a printed unique backup path.
This is not a published package-manager distribution.

With no `--project`, the CLI searches cwd and its ancestors for `flux.json`.
`flux --project /path/to/app build` and `flux build --project ../app` both work.
Paths are relative to cwd, **not** the framework checkout. Running `./flux` at
the Flux root still defaults to `platform/crud`. `new` still creates and registers
a reviewed starter under the framework's `apps/`; external scaffolding is not
part of this change.

## Format 2

```json
{
  "format": 2,
  "schema": "api/schema.json",
  "server": "server.ipkg",
  "ui": "ui.ipkg",
  "sources": ["src"],
  "generated": {
    "directory": "src/Generated",
    "namespace": "Generated",
    "openapi": "api/openapi.json"
  },
  "public": {
    "directory": "public",
    "files": ["index.html", "app.css", "onboarding.css", "assets/*.png"]
  },
  "dependencies": "managed",
  "database": "postgres",
  "run": {"web": true},
  "tests": [["python3", "tests/test_app.py"]]
}
```

- `sources` covers both ipkg source directories. Manifest `sourcedir` paths stay
  inside the application; dependencies may point to selected framework packages.
  Package manifests use the standard `build/exec` output layout.
- `generated.directory` is the final directory for ProtocolTypes/Protocol/Client.
  The generator itself emits the optional namespace, including internal imports.
  OpenAPI has a separate destination; do not hand-edit generated files.
- `public.files` is an explicit allowlist of relative glob patterns. Only web
  extensions and conservative URL filenames are accepted. Hidden/private files,
  escaping paths and symlinks are rejected. Index and app.css are required;
  `/app.js` is reserved for the compiler. Additional CSS, images, fonts and other
  selected assets keep their normal relative URLs; no application-specific
  inlining or data-URL conversion occurs. `/` aliases `/index.html`.
- `dependencies=managed` makes `flux sync` generate a local `pack.toml` from the
  application's transitive Flux dependencies and selected checkout's collection.
  Commit/review it. Build/check reject stale maps and browser dependencies on
  server-only packages. Unknown external dependencies remain pack's responsibility.
  Flux's workspace manifest/map are not modified. `workspace` retains the shared
  map used by existing in-checkout examples (`tools/workspace.py sync`).
- `database=postgres` requires explicit PGHOST, PGPORT, PGUSER, PGPASSWORD and
  PGDATABASE, or deliberate `--disposable-db`. `none` skips database management
  and rejects that flag. Provider credentials/modes are never inferred by Flux.
- `run.web=true` declares native asset integration described below.
- Optional `tests` contains argv arrays, executed in the application directory by
  `flux test`, without shell expansion. These are trusted local project commands.

Unknown/duplicate keys and invalid types are rejected. Existing exact format-1
configs remain supported: root-level generated/public files, workspace dependencies
for in-checkout apps (managed for external apps), PostgreSQL and API-only native
servers. They can continue using `dev`. Format-2 optional fields use those defaults;
explicit fields are recommended for external projects. Native `run` requires the
format-2 web declaration and server integration, not merely renaming `dev`.

## Commands and artifacts

- `sync`: regenerate a managed application's dependency map; never install packages
  or modify the framework workspace registrations.
- `generate [--check]`: generate/verify the schema outputs. `--check` never writes.
- `check`: validate configuration, selected assets, local dependency map, browser
  dependency boundary and generated freshness. It is not an Idris typecheck;
  `build` compiles both targets.
- `build`: check generated freshness, build server/UI, then atomically publish
  `.workspace/application.json` pointing to a new immutable release. Failure leaves
  the previous release selected. Releases include native libraries and only
  allowlisted web assets, without development scripts or source code.
- `dev [--watch|--hot] [--no-build]`: development proxy, same-origin RPC forwarding,
  optional compiler/error overlay and live reload. Public files and native runtimes
  are staged into owned `.workspace/stage-*` snapshots. Normal shutdown removes
  those stages after stopping backends; abrupt termination may leave them behind.
  Stages accumulate during the session to keep active backend working directories
  immutable. Do not run concurrent builds against the same manifests.
- `run`: verify the last published artifact's configuration/hashes and launch its
  native server directly. No compilation, polling, proxy or HMR injection. Source
  edits do not alter that release; rebuild to deploy them. Edited/missing artifacts
  fail closed. `--port 0` selects a free port; default port is 8090.
- `migrate`: invoke the built compiler output with `--migrate-only`; retain the
  application's explicit frozen-migration and database ownership contract.

Both dev/run own process shutdown and any disposable database. An unavailable
Docker daemon is reported before creation, without claiming a container exists.
If creation was attempted and removal fails, diagnostics retain the initial error
and the exact owned container/removal command. Neither path resets an existing
PG database or retries RPC writes. Releases remain for inspection/rollback tooling;
remove unused `.workspace/releases/*` only when no process uses them.

## Native web integration (flux >= 0.3.0)

Declare a **direct** `flux >= 0.3.0` dependency in the server ipkg, then:

```idris
import Flux.Server.Assets

-- After creating your application's RPC routers, before runServerArgs:
assets <- webAssetsFromEnv
let routes = MkRouter (accounts.routes ++ application.routes ++ assets.routes)
```

`flux run` sets `FLUX_PUBLIC_DIR` to the verified release's private `.public`
directory. `webAssetsFromEnv` loads its `.flux-assets` allowlist and registers exact
GET routes through Flux's traversal/symlink-safe static middleware, after RPC routes.
It sets MIME/nosniff/cache headers and an asset readiness marker. The manifest itself
is not served. Without the environment variable it adds no routes; `dev` explicitly
unsets it for its API processes. A declared but unintegrated server fails the run
readiness check rather than silently starting an API-only service.

This native runner is not a production deployment promise: TLS termination,
operational supervision, durable database provisioning and backups remain explicit
application/deployment responsibilities. Existing authentication/ownership rules
and [watch migration caveats](DEV_RELOAD.md) continue to apply. HMR still requires
an [explicit compatible state codec](DEV_HMR.md).

## Verification

```sh
python3 -m unittest discover -s tools -p 'test_*.py'
./flux check
./flux build
# From the sibling Chequra application:
cd ../chequra
flux check
flux build
flux test
```

Tooling tests cover external discovery/configuration, namespaces, dependency-map
isolation, browser boundaries, public allowlists, immutable artifacts, failed-build
publication, staging cleanup, installer backups and legacy example compatibility.
Chequra's owned PostgreSQL/browser suite runs through both `dev` and native `run`,
checking assets/private-file exclusion, onboarding, authentication, owner isolation,
exact GBP/NGN accounting, idempotency, restart and cleanup. Its separate real-Idris
HMR codec acceptance uses explicitly mocked RPC responses.
