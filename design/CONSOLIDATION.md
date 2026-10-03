# Flux: full-stack Idris applications (preview)

Flux is the umbrella platform. This change consolidates source ownership into
one modular repository; it does not merge the UI and server runtimes, rename
every public API, or establish production readiness.

## Source and package map

| Platform area / intended public name | Source | Current package ID |
| --- | --- | --- |
| flux-server | repository root `src/` | `flux` |
| flux-runtime | `packages/runtime/` | `flux-runtime` |
| db | external (pinned git dependency, not vendored) | `db` |
| postgres / postgres-async | external (pinned git dependency, not vendored) | `postgres`, `postgres-async` |
| flux-ui (UI framework) | external (pinned git dependency, not vendored) | `iris` |
| Server/database integration | `packages/db-flux/` | `flux-db-flux` |
| flux-client | `platform/client/` | `flux-client` |
| flux-protocol | `platform/` | `flux-protocol` |
| Example application | `examples/todo-api/` | `todo-api` |
| Local container helper | external (pinned git dependency, not vendored) | `docker` |
| Application CLI | repository-local `./flux` | no published package yet |

The UI framework is [odunboye/iris](https://github.com/odunboye/iris) (package
`iris`, `Iris.*` modules) - a pinned external dependency, not vendored here,
reclaiming the framework's own pre-Flux name; see its own `MIGRATION.md` for
its historical breaking renames (it was briefly `flux-ui`/`Flux.UI.*` while
vendored inside Flux).
Persistence is also renamed outright to `flux-db` / `flux-db-flux` and
`Flux.DB.*`. Existing databases require the explicit
[metadata cutover](https://github.com/odunboye/db/blob/main/MIGRATION.md); old
history must not be replayed.
The runtime, protocol/client and Docker packages also use the current names
above, without old-name package aliases. See the
[coordinated package migration](PACKAGE_MIGRATION.md). These are workspace-local
packages, not additional published registry entries. PostgreSQL support
(`postgres`/`postgres-async`), the active-record/query-builder layer (`db`,
formerly `flux-db`), and the UI framework (`iris`, formerly vendored as
`flux-ui`) are the exceptions: all three were later moved back out to their
own repos - `postgres` first under its original `idris2-pg`/
`idris2-pg-async` names and then renamed there to `postgres`/`postgres-async`;
`db` straight to its current name, dropping the `Flux.DB.*` module prefix
along with it, since `Flux.DB.PG`/`Flux.DB.Pool` (the one genuinely
Flux-specific part) stayed behind as `flux-db-flux`; `iris` reclaiming its
own pre-Flux name, dropping the `Flux.UI.*` module prefix (and the
public-facing DOM/JS/native runtime identifiers baked into it) back to
`Iris.*` - see the package map above and `workspace.json`'s
`external_packages` - so each is a pinned external dependency, not a
workspace-local package. Server source stays at the root.

`workspace.json` is the canonical map. `pack.toml` is generated from it; nested
package configs were removed to prevent stale sibling/absolute paths from
silently selecting the old repositories. Third-party dependencies remain
managed by pack's pinned `nightly-260903` collection (Idris2 0.8.0 compiler
commit recorded in the manifest). Node 20+ with fetch and Python 3.9+ are
required for the integration harness. Browser tests require Chromium and
Playwright; database tests require Docker and a local `postgres:16` image.

## History and ownership

Runtime, PostgreSQL, Flux DB, Flux DB/Flux integration, Iris, and todo-api were
imported with **unsquashed Git subtrees**. Original commits are ancestors of the
consolidated branch, not flattened snapshots. `workspace.json` records each
source tip. Original repositories were not deleted, rewritten or modified by
the imports; they remain historical references. New platform development should
use the copies in this repository, not maintain two competing authoritative
working trees.

`flux-docker` had no Git repository. Its source, package, README and tests were
copied explicitly, excluding build outputs. No nonexistent history is claimed.
The repository records its first version as part of this consolidation. It was
later moved back out to its own repo and renamed `docker` (see the package map
above), for the same reason as `db`/`postgres`: no Flux-specific dependencies.
That new repo's own first commit is a fresh start too, for the same reason -
there was never any history to carry over.

Old verification reports and imported historical investigation notes retain
some pre-consolidation paths and commands for provenance. Use this document,
the root README and current workspace scripts for the supported layout.

## Developer workflow

```sh
# From a clean Flux checkout:
python3 tools/workspace.py check
pack --no-prompt build flux.ipkg

# For browser/database integration:
npm ci
npx playwright install chromium
docker pull postgres:16
python3 tools/workspace.py test
```

On Linux, Chromium may additionally require system libraries (Playwright's
`install --with-deps chromium` can install these in a suitable CI image).
`test` builds the native iris dependency before JS clients, compiles server and
client examples, checks generation, runs Flux regressions, and exercises the
native/browser wire, pooled PostgreSQL/migration and complete CRUD suites.
Database tests create and remove their own disposable containers. They never
reset an application database. Logs and command exit codes are saved under
`.workspace/reports/<timestamp>/` (outside `build/`, which pack may clean).

`--without-db` explicitly skips database integration and reports that skip; it
is not equivalent to the full integration gate. This combined command does not
replace every library's native sanitizer, property, soak or platform-specific
suite. Individual package builds remain available, for example:

```sh
(cd packages/db-flux && pack --no-prompt build flux-db-flux.ipkg)
pack --no-prompt build iris  # fetches github.com/odunboye/iris at the pinned commit
(cd platform && pack --no-prompt build crud/server.ipkg)
```

After changing package locations or IDs, edit `workspace.json`, run
`python3 tools/workspace.py sync`, and rerun the checks. The workspace utility
remains workspace tooling. The separate repository-local `./flux` application
CLI now implements `new`, `doctor`, `generate`, `build`, `migrate` and `dev`;
see the [application guide](../platform/crud/README.md).

## Root CI coverage

The root `.github/workflows/ci.yml` runs one independent platform job on
pull requests and main pushes, in addition to the existing boundary/HTTP jobs:

- **generated-client-db**: the complete `workspace.py test` gate, including
  generated-output freshness, native/JS clients, Chromium, disposable PostgreSQL,
  migrations and full CRUD, plus fresh-source CLI project creation/build and
  actual Iris acceptance against PostgreSQL. It also builds the native Flux
  landing server and checks its responsive page in Chromium. Database checks
  are not skipped.

Iris's own unit tests, web/mobile bundle builds, release-asset validation and
Playwright browser integration tests now run in
[its own repo](https://github.com/odunboye/iris) and its own CI, not here -
it was extracted along with `packages/ui` since it has no Flux-specific
dependencies. The root job installs locked browser dependencies, audits them,
retains logs/failure traces even on failure, and has a 45-minute job timeout.
Configure branch protection to require this named check as well as the
existing checks; workflow code does not change repository protection settings.

`bash tools/ci-linux.sh platform` reproduces the CI setup on an Ubuntu Docker
host with Node 20+. The launcher uses the pack compiler image, the root
pinned collection, a Docker socket and explicit host networking so disposable
PostgreSQL ports remain accessible inside the test container. Use this
launcher only on a trusted, disposable Docker host, as in GitHub-hosted CI.
With prerequisites already installed, the portable test-only command is
`bash tools/ci-suite.sh platform`.

## Dependency boundary

The Iris client uses Iris lifecycle/effects, not the Chez owned server runtime.
`flux-client` depends on Iris/json-simple and generated shared wire
types. UI/client packages must not transitively depend on `flux`, `flux-runtime`,
Flux DB, PostgreSQL, or the server endpoint package. The workspace check enforces
this across local `.ipkg` dependency declarations. Version bounds are stripped
before graph traversal, including multiline bounds and compact comparisons
such as `server>=0.1.0`. Direct and transitive version-qualified forbidden edges
are regression-tested; unsupported name syntax and duplicate `depends`
declarations fail closed.

Flux DB is currently PostgreSQL-backed; the `db`/`flux-db-flux` umbrella label does not
claim that it already abstracts every database backend. Keep SQL protocol and
pool ownership in the PostgreSQL packages while persistence models, queries,
repositories and migrations remain in the database layer.

## Next platform gates

CRUD, collections, explicit nullability, Iris client commands, keyset pagination,
and migration-backed example startup are implemented and committed.

The complete todo Iris and initial workspace application CLI/template are
implemented and verified together. Remaining tooling includes standalone SDK
packaging, watch/reload, migration planning and production deployment.

1. Broaden the UI/project workflow beyond the reviewed todo starter.
2. Authenticated PostgreSQL TLS, user identity, authorization and row ownership.
3. Supported deployment, operational tooling, and reproducible release CI.
4. Further public package naming decisions; the Iris breaking rename is complete.

No managed cloud, security completion, universal UI parity, or production-ready
release is implied by putting the code in one repository.
