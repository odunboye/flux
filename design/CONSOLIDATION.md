# Flux: full-stack Idris applications (preview)

Flux is the umbrella platform. This change consolidates source ownership into
one modular repository; it does not merge the UI and server runtimes, rename
every public API, or establish production readiness.

## Source and package map

| Platform area / intended public name | Source | Current package ID (compatible) |
| --- | --- | --- |
| flux-server | repository root `src/` | `flux` |
| flux-runtime | `packages/runtime/` | `flux-async` |
| flux-ui | `packages/ui/` | `iris` |
| flux-db | `packages/db/` | `nebula` |
| flux-db-postgres | `packages/postgres/`, including `async/` | `idris2-pg`, `idris2-pg-async` |
| Server/database integration | `packages/db-flux/` | `nebula-flux` |
| flux-client | `platform/client/` | `flux-platform-client` |
| flux-platform | `platform/` | `flux-platform` |
| Example application | `apps/todo-api/` | `todo-api` |
| Local container helper | `packages/docker/` | `idris2-docker` |
| Future flux-cli | not yet implemented | none |

The intended public names are **not additional published packages yet**.
Existing package IDs, `Flux.*`, `Iris.*`, `Data.PG*`, and `Nebula.*` imports
continue working. Server source remains at the root to preserve existing build
commands; namespace and directory migrations are separate future changes.

`workspace.json` is the canonical map. `pack.toml` is generated from it; nested
package configs were removed to prevent stale sibling/absolute paths from
silently selecting the old repositories. Third-party dependencies remain
managed by pack's pinned `nightly-260903` collection (Idris2 0.8.0 compiler
commit recorded in the manifest). Node 20+ with fetch and Python 3.9+ are
required for the integration harness. Browser tests require Chromium and
Playwright; database tests require Docker and a local `postgres:16` image.

## History and ownership

Runtime, PostgreSQL, Nebula, Nebula/Flux integration, Iris, and todo-api were
imported with **unsquashed Git subtrees**. Original commits are ancestors of the
consolidated branch, not flattened snapshots. `workspace.json` records each
source tip. Original repositories were not deleted, rewritten or modified by
the imports; they remain historical references. New platform development should
use the copies in this repository, not maintain two competing authoritative
working trees.

`idris2-docker` had no Git repository. Its source, package, README and tests were
copied explicitly, excluding build outputs. No nonexistent history is claimed.
The repository records its first version as part of this consolidation.

Old verification reports and imported historical investigation notes retain
some pre-consolidation paths and commands for provenance. Use this document,
the root README and current workspace scripts for the supported layout.

## Developer workflow

```sh
# From a clean Flux checkout:
python3 tools/workspace.py check
pack --no-prompt build flux.ipkg

# For browser/database integration:
(cd packages/ui && npm ci)
(cd packages/ui && npx playwright install chromium)
docker pull postgres:16
python3 tools/workspace.py test
```

On Linux, Chromium may additionally require system libraries (Playwright's
`install --with-deps chromium` can install these in a suitable CI image).
`test` builds the native Iris dependency before JS clients, compiles server and
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
(cd packages/db && pack --no-prompt build nebula.ipkg)
(cd packages/ui && pack --no-prompt build iris.ipkg)
(cd platform && pack --no-prompt build crud/server.ipkg)
```

After changing package locations or IDs, edit `workspace.json`, run
`python3 tools/workspace.py sync`, and rerun the checks. The workspace utility
remains workspace tooling. The separate repository-local `./flux` application
CLI now implements `new`, `doctor`, `generate`, `build`, `migrate` and `dev`;
see the [application guide](../platform/crud/README.md).

## Root CI coverage

The root `.github/workflows/ci.yml` now runs two independent platform jobs on
pull requests and main pushes, in addition to the existing boundary/HTTP jobs:

- **iris-ui-browser**: Iris unit tests, web/mobile bundle builds and release-asset
  validation (`make check`), then all Playwright browser integration tests.
- **generated-client-db**: the complete `workspace.py test` gate, including
  generated-output freshness, native/JS clients, Chromium, disposable PostgreSQL,
  migrations and full CRUD, plus fresh-source CLI project creation/build and
  actual Iris UI acceptance against PostgreSQL. Database checks are not skipped.

The old nested Iris workflow was removed; GitHub never executed it from inside
`packages/ui`. Both root jobs install locked browser dependencies, audit them,
retain logs/failure traces even on failure, and have a 45-minute job timeout.
Configure branch protection to require these named checks as well as the
existing checks; workflow code does not change repository protection settings.

`bash tools/ci-linux.sh ui` and `bash tools/ci-linux.sh platform` reproduce the
CI setup on an Ubuntu Docker host with Node 20+. The launcher uses the pack
compiler image, the root pinned collection, a Docker socket and explicit host
networking so disposable PostgreSQL ports remain accessible inside the test
container. Use this launcher only on a trusted, disposable Docker host, as in
GitHub-hosted CI. With prerequisites already installed, the portable test-only
commands are `bash tools/ci-suite.sh ui` and `bash tools/ci-suite.sh platform`.
The UI lane explicitly selects pack's compiler rather than a possibly
incompatible system `idris2`.

## Dependency boundary

The Iris client uses Iris lifecycle/effects, not the Chez owned server runtime.
`flux-platform-client` depends on Iris/json-simple and generated shared wire
types. UI/client packages must not transitively depend on `flux`, `flux-async`,
Nebula, PostgreSQL, or the server endpoint package. The workspace check enforces
this across local `.ipkg` dependency declarations. Version bounds are stripped
before graph traversal, including multiline bounds and compact comparisons
such as `server>=0.1.0`. Direct and transitive version-qualified forbidden edges
are regression-tested; unsupported name syntax and duplicate `depends`
declarations fail closed.

Nebula is currently PostgreSQL-backed; the `flux-db` umbrella label does not
claim that it already abstracts every database backend. Keep SQL protocol and
pool ownership in the PostgreSQL packages while persistence models, queries,
repositories and migrations remain in the database layer.

## Next platform gates

CRUD, collections, explicit nullability, Iris client commands, keyset pagination,
and migration-backed example startup are implemented and committed.

The complete todo Iris UI and initial workspace application CLI/template are
implemented and verified together. Remaining tooling includes standalone SDK
packaging, watch/reload, migration planning and production deployment.

1. Broaden the UI/project workflow beyond the reviewed todo starter.
2. Authenticated PostgreSQL TLS, user identity, authorization and row ownership.
3. Supported deployment, operational tooling, and reproducible release CI.
4. Gradual public entry-module/package naming migration with compatibility tests.

No managed cloud, security completion, universal UI parity, or production-ready
release is implied by putting the code in one repository.
