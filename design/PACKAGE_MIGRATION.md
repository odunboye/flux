# Coordinated platform package rename

All six library package renames land together, with no old-name alias packages.
The main server remains `flux`; Flux UI and Flux DB keep their current names.

| Old package | Current package | Package file |
| --- | --- | --- |
| `flux-async` | `flux-runtime` | `packages/runtime/flux-runtime.ipkg` |
| `flux-platform-client` | `flux-client` | `platform/flux-client.ipkg` |
| `flux-platform` | `flux-protocol` | `platform/flux-protocol.ipkg` |
| `idris2-pg` | `flux-postgres` | `packages/postgres/flux-postgres.ipkg` |
| `idris2-pg-async` | `flux-postgres-pool` | `packages/postgres/async/flux-postgres-pool.ipkg` |
| `idris2-docker` | `flux-docker` | `packages/docker/flux-docker.ipkg` |

Related transport/Docker test package and executable prefixes are renamed too.
Directories are unchanged; the canonical map is still `workspace.json`, with
`pack.toml` generated from it. These are workspace-local packages, not a claim
that new packages have been published to an external registry.

## What to change

Update `.ipkg` dependencies, package-file paths, install/build commands and any
scripts selecting test executables by the old names. Rebuild consumers against
the new packages, including handwritten applications created by earlier CLI
versions. No compatibility manifests remain for the old package names.

Existing suitable **module namespaces stay unchanged**:

- Runtime: `Flux.Async.*`, `Flux.IO.*`, and its other existing `Flux.*` modules.
- Protocols/client: `Flux.Platform.*`, including `Flux.Platform.Client.*`.
- PostgreSQL: `Idris2_pg`, `Data.PG*`, `Network.*` and `Crypto.*`.
- Docker: `Docker`.

These are their original defining modules, not wrappers. This batch does not
rename native FFI symbols, environment-variable contracts, SQL objects, RPC
routes, schemas or application data. In particular, `flux_db_meta.migrations`,
its lock key and frozen migration checksums are unchanged. The earlier
[Flux DB cutover](../packages/db/MIGRATION.md) is still required if upgrading a
pre-Flux-DB database; this batch introduces no further database cutover.

## Build and verify

From the Flux root:

```sh
python3 tools/workspace.py check
pack --no-prompt install flux-runtime
pack --no-prompt install flux-postgres
pack --no-prompt install flux-postgres-pool
pack --no-prompt install flux-docker
./flux build
python3 tools/workspace.py test
```

Native dependencies must be installed before browser compilation. Do not run
multiple pack builds/installations concurrently against the same workspace and
cache. Independent source edits, unit checks and lint checks can run in parallel;
shared manifest integration and compiler builds are serialized.

The browser closure now uses `flux-client`; `flux-runtime`, `flux-protocol`,
`flux-postgres`, `flux-postgres-pool`, and the DB/server packages remain forbidden
in that closure. Current package names/dependencies are checked in root CI.

Original subtree source names, source commits, historical reports and prior
migration records retain their original meaning. Original sibling repositories
and unrelated files are untouched. Old globally installed packages/build caches
may still exist outside this workspace; they are not compatibility packages
provided by this source tree.
