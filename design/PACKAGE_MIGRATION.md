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

**The `idris2-pg`/`idris2-pg-async` row above was later reversed, then renamed
again.** PostgreSQL support moved back out to its own repo
([odunboye/postgres](https://github.com/odunboye/postgres)) so
it isn't Flux-only, first under its original name (`idris2-pg`), then renamed
there to `postgres` (`idris2-pg-async` to `postgres-async`) once it was its
own repo and no longer needed the `idris2-` prefix to disambiguate from
Flux's vendored copy. See `design/CONSOLIDATION.md`'s package map and
`workspace.json`'s `external_packages` for the current state. This row is
kept here as the historical record of this batch's rename, not current
guidance - don't install or depend on `flux-postgres`/`flux-postgres-pool`,
they no longer exist.

**The `idris2-docker`/`flux-docker` row was later reversed too**, moving back
out to [odunboye/docker](https://github.com/odunboye/docker) and renamed
`docker` directly (it never had an `idris2-` row to revert to - the original
`idris2-docker` checkout had no Git history, so this was always a from-scratch
repo either way). Don't install or depend on `flux-docker`, it no longer
exists.

**The `flux-async`/`flux-runtime` row above was later reversed too.** The
owned runtime moved back out to its own repo,
[odunboye/idris2-flux-async](https://github.com/odunboye/idris2-flux-async),
since it has no Flux-specific dependencies either, the same reasoning as
`db`/`postgres`/`docker`. It kept the `flux-async` name there - that repo had
already been published under that name so `postgres-async` (an external git
dependency with no visibility into this workspace's local aliases) could
resolve its own `flux-async` dependency; Flux itself now depends on the same
external package instead of vendoring a second copy as `flux-runtime`. See
`design/CONSOLIDATION.md`'s package map and `workspace.json`'s
`external_packages` for the current state. Module namespaces
(`Flux.Async.*`/`Flux.Stream.*`) are unchanged. Don't install or depend on
`flux-runtime`, it no longer exists.

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
pack --no-prompt install flux-async
pack --no-prompt install postgres
pack --no-prompt install postgres-async
pack --no-prompt install db
pack --no-prompt install docker
./flux build
python3 tools/workspace.py test
```

Native dependencies must be installed before browser compilation. Do not run
multiple pack builds/installations concurrently against the same workspace and
cache. Independent source edits, unit checks and lint checks can run in parallel;
shared manifest integration and compiler builds are serialized.

The browser closure now uses `flux-client`; `flux-async`, `flux-protocol`,
`postgres`, `postgres-async`, and the DB/server packages remain forbidden
in that closure. Current package names/dependencies are checked in root CI.

Original subtree source names, source commits, historical reports and prior
migration records retain their original meaning. Original sibling repositories
and unrelated files are untouched. Old globally installed packages/build caches
may still exist outside this workspace; they are not compatibility packages
provided by this source tree.
