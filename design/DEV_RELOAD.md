# Flux development live reload

`flux dev --watch` adds live reload to the application CLI (or `./flux` in the checkout).
See [application configuration/install](APPLICATION_CLI.md) for external projects.
Plain `--watch` is not state-preserving hot-module replacement. Add `--hot` for
[opt-in DOM model-preserving replacement](DEV_HMR.md), using an application codec.
Neither mode is enabled by `build`, `run`, `migrate` or ordinary `dev`.

```sh
./flux dev --watch --disposable-db
# Reuse an existing successful initial build:
./flux dev --watch --no-build --disposable-db --port 8090
# External application using the same framework service:
cd ../chequra
CHEQURA_PROVIDER=simulated flux dev --watch --no-build --disposable-db --port 8091
```

Without `--disposable-db`, explicitly configure the same dedicated PG* database
as for ordinary dev. The database context surrounds the whole watch session;
rebuilds do not recreate, reset or remove it. Ctrl-C/SIGTERM owns compiler groups,
HTTP handlers, active/candidate native processes and eventual database cleanup.
Do not run concurrent pack builds/watchers against the same checkout: builds are
serialized within a watch session, not globally across independent pack clients.

## Change policy

| Change | Action after a successful build/stage |
| --- | --- |
| CSS | Replace `/app.css` link after its replacement loads; retain browser model, inputs and bearer |
| HTML or image/font assets | Reload page |
| Application UI `.idr` module | Rebuild browser executable, reload page |
| Application server `.idr` module | Rebuild native executable, start candidate, switch proxy, reload page |
| Shared module, manifests or dependency configuration | Rebuild both targets, switch/reload together |
| API schema or generator | Generate, check generated output, rebuild both targets |
| Local transitive dependency | Rebuild the target(s) which depend on it |
| Native C/header/Scheme/Makefile | Refresh local prebuild manifest timestamps, then rebuild dependent target(s) |

Unknown new application Idris files conservatively rebuild both targets. Root
manifests supply module ownership; transitive local package roots come from the
workspace package map. Installed dependencies outside that map are not watched.
Native refresh is necessary because pack's freshness tracking does not see C
changes. `.ipkg` content fingerprints keep timestamp-only refreshes from feeding
back into the watcher.

Polling observes creation, modification, deletion and atomic editor saves. Saves
are debounced (300ms); builds run on one worker. Saves during a build queue another
build of the union of affected targets. A superseded candidate is discarded
rather than exposed. Failed targets remain in the next rebuild's target set so a
later CSS save cannot accidentally publish corrupt JS from a failed compiler.

`build`, `.workspace`, `.git`, `node_modules`, tests, documentation/design folders,
hidden files and explicitly generated output paths are excluded. Directory
symlinks and symlinked source files are not followed. Changes to the running
Python dev implementation require restarting dev; this is not a Python module
reloader. Application layouts and exclusions come from `flux.json`.

## Publication and process ownership

The HTTP server serves an immutable in-memory snapshot of the last successful
HTML/CSS/JS, not files which the compiler is currently truncating/replacing.
One locked publication switches that asset map and backend address. Failed
compilation/staging/startup leaves the prior map and backend in place.

Each native candidate gets a private copy of the Chez `_app` directory, including
its adjacent native libraries. The old executable therefore cannot load newly
replaced build libraries. Default readiness is successful loopback TCP connect
while the candidate is alive, with a 30-second bound; applications can add a
readiness predicate. After publication, the old API receives SIGTERM and up to
40 seconds to drain, then bounded process-group cleanup. The proxy captures a
backend address once per request; it never retries or replays a write, including
on connection interruption during a cutover.

Candidate and old API can briefly coexist against the same database. **Startup
migrations are still application side effects, not transactional with asset
publication.** Use compatible explicit migrations; rolling back a failed candidate
does not undo database changes it already made. There is no automated migration
rollback or database reset. Side-effectful startup workers require application
coordination before opting into overlapping candidates.

This is a single development service, not a production deployment strategy.
External interruption may still leave ambiguous write outcomes: inspect existing
operations rather than replaying writes. Abrupt SIGKILL/power loss cannot execute
normal cleanup. Blocking arbitrary custom hook code cannot be forcibly cancelled
like the framework's owned compiler subprocesses.

## Browser client and diagnostics

The served HTML receives external `/__flux_dev/client.js` and `client.css` links;
source HTML and production output are unchanged. HTML needs an explicit closing
`</head>` (case-insensitive); staging reports a clear error if it is absent.
Same-origin script/style/connect
CSP rules suffice; no `unsafe-inline` or websocket allowance is needed. Hosts with
custom CSPs must permit those local development resources.

A 500ms status poll returns a session ID, CSS/reload revisions, build state and a
bounded compiler error. HTML embeds its starting revision so reconnecting clients
cannot miss a completed build. A new server session also triggers reload. CSS
refresh retains the old stylesheet on load failure and retries later. Network
interruption reconnects without replaying any application RPC.

The overlay lives outside the application mount and renders diagnostics using
`textContent`, never `innerHTML`. Subprocess output is bounded; environment values
whose keys identify passwords/tokens/secrets/credentials are redacted. Do not put
other secrets in source/compiler messages. The watch GET routes enforce the
loopback Host and same-origin Origin, return no-store responses, and do not grant
CORS. Only the existing explicit asset allowlist and these three dev routes are
served—never source files, configuration or arbitrary paths. Ordinary non-watch
dev continues returning 404 for development routes.

The optional `--hot` mode adds `/__flux_dev/hot.js` and version-pinned UI bundle
requests; only compatible UI publications avoid full reload in that mode.

A full reload intentionally loses in-memory authentication and onboarding state.
The framework does not store or transplant bearer tokens to avoid that. CSS-only
refresh does not remount the application.

## Framework policy and advanced hooks

Ordinary applications use format-2 `flux.json`, not custom Python hooks. Flux owns
transitive dependency discovery, namespaced generation, asset selection, native
staging and HMR eligibility. Additional selected CSS/images/fonts are served through
the same exact allowlist in both ordinary and watch dev. Immutable temporary stages
are cleaned on normal session exit; they accumulate during a session so a running
backend never sees its working directory rewritten.

For advanced framework integrations only, the experimental Python API is `flux.dev(project, config, env, port, watch=hooks)`:

```python
from devwatch import DevHooks, WatchPath, package_sources

hooks = DevHooks(
    sources=lambda: [WatchPath(source_dir, 'both'),
                     WatchPath(public_dir, 'assets')],
    build=rebuild,       # rebuild(kinds: set[str], runner: BuildRunner)
    stage=stage_assets,  # returns (directory, config)
    exclude=(generated_dir,),
    ready=None,         # optional (port, subprocess) -> bool, must be bounded
    hot=False,          # opt into runWebHot-aware DOM bundle replacement
)
```

- `sources` runs repeatedly and can re-read manifests to discover new local
  dependencies. More-specific watch paths override parent classifications. Equal
  paths union targets. Kinds are `ui`, `server`, `both`, `schema`, `css`, `reload`;
  `assets` classifies CSS versus other assets. Native files add `native`.
- `build` skips compilers for CSS/assets, runs generation for schema changes, and
  invokes `runner.run(argv, cwd=..., timeout=...)` for compilers/generators. Use the
  runner rather than detached subprocesses: it supplies bounded logs, deadlines,
  process-group cancellation and secret redaction. `refresh_native(sources())`
  handles pack prebuild freshness when `native` is present.
- `stage` runs after success, returning the standard dev layout (`index.html`,
  `app.css`, package manifests and `build/exec` outputs). The default framework
  policy copies explicitly selected public files, without application-specific
  transformations. `flux.staging_session()` owns temporary stage cleanup.
- `exclude` is an iterable or callable returning generated paths. It must cover
  every generated source output so generation cannot cause a build loop. Default
  Flux hooks derive these paths dynamically from the current `flux.json`, including
  namespaced Idris output and a separately located OpenAPI file.

Hooks are trusted local build code. They must not create unowned background work
or mutate an existing database as part of asset staging.

## Verification

```sh
python3 -m unittest discover -s tools -p 'test_devwatch.py' -v
python3 -m unittest discover -s tools -p 'test_flux.py' -v
```

Tests cover target discovery, exclusions, native freshness, deleted-file recovery,
rapid saves and superseded builds, failed builds retaining published bytes,
backend startup failure/rollback, cutover without replay, schema rebuild dispatch,
restricted routes, and shutdown during compilation. Native-process tests use a
small HTTP fixture rather than PostgreSQL/Idris, so they run without Docker.
With this repo's own (`npm install` at the root) Playwright dependencies and Chromium installed, browser tests
also check CSS state preservation, safe error rendering, successful JS reload,
and polling reconnection. They are skipped when the Playwright package is absent.
If `examples/examples.ipkg` has already been built, an additional test launches
two real Chez runtime snapshots and verifies an admitted `/slow` request drains
successfully while the old generation stops. Otherwise that native check is
skipped. The suite is included in `tools/workspace.py test`.
