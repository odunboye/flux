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

**Flux UI (`flux-ui`), which this batch's intro says "keeps its current
name," was later moved out too.** It moved back to its own repo,
[odunboye/iris](https://github.com/odunboye/iris), reclaiming the framework's
own pre-Flux name (`iris`, `Iris.*` modules, dropping the `Flux.UI.*` prefix
and the public-facing DOM/JS/native runtime identifiers baked into it), since
it has no Flux-specific dependencies - the same reasoning as
`db`/`postgres`/`docker`. See `design/CONSOLIDATION.md`'s package map and
`workspace.json`'s `external_packages` for the current state. Don't install
or depend on `flux-ui`, it no longer exists; see
[its own MIGRATION.md](https://github.com/odunboye/iris/blob/main/MIGRATION.md)
for its own earlier breaking renames.

**The `flux-async`/`flux-runtime` row above was later reversed too, then
renamed again.** The owned runtime moved back out to its own repo, first
published as [odunboye/idris2-flux-async](https://github.com/odunboye/idris2-flux-async)
under the `flux-async` name - that repo had already been published under
that name so `postgres-async` (an external git dependency with no visibility
into this workspace's local aliases) could resolve its own `flux-async`
dependency - since it has no Flux-specific dependencies either, the same
reasoning as `db`/`postgres`/`docker`. It was then renamed there too, to
[odunboye/runtime](https://github.com/odunboye/runtime) (package `runtime`),
once it no longer needed a Flux-specific name to disambiguate from Flux's
vendored copy (which was removed in the same move that published it
externally); `postgres-async`'s own dependency was updated to match. Flux
itself depends on the same external package instead of vendoring a second
copy as `flux-runtime`. See `design/CONSOLIDATION.md`'s package map and
`workspace.json`'s `external_packages` for the current state. Module
namespaces changed along with this second rename: `Flux.Async.*`/
`Flux.Stream.*` became `Async.*`/`Stream.*`. Don't install or depend on
`flux-runtime` or `flux-async`, neither exists any more.

**The `flux-platform-client`/`flux-client` row above was later moved out
too**, once `iris` (above) moved out and `flux-client` turned out to have no
real Flux dependency either - it only ever depended on `flux-ui`/`iris` and
`json-simple`. It moved into the same repo as `iris`, as the `iris-client`
sub-package (`client/iris-client.ipkg`), dropping the `Flux.Platform.Client.*`
module prefix to `Iris.Client.*`. See `design/CONSOLIDATION.md`'s package map
and `workspace.json`'s `external_packages.iris-client` for the current state.
`flux-mobile`, which depended on `flux-client`, moved to the same repo too as
`iris-mobile` for the same reason, but was never a workspace-registered
package to begin with (resolved only via `tools/mobile_check.py`'s own
temporary Pack map, like `capacitor`) so there's no row for it above. Don't
install or depend on `flux-client`, it no longer exists.

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

- Runtime: `Flux.Async.*`, `Flux.IO.*`, and its other existing `Flux.*` modules
  at the time of this batch (later renamed `Async.*`/`Stream.*` when the
  package moved out to its own repo - see the reversal note above).
- Protocols/client: `Flux.Platform.*` at the time of this batch (the client
  half, `Flux.Platform.Client.*`, was later renamed `Iris.Client.*` when
  `flux-client` moved out to its own repo - see the reversal note above).
- PostgreSQL: `Idris2_pg`, `Data.PG*`, `Network.*` and `Crypto.*`.
- Docker: `Docker`.

These are their original defining modules, not wrappers. This batch does not
rename native FFI symbols, environment-variable contracts, SQL objects, RPC
routes, schemas or application data. In particular, `flux_db_meta.migrations`,
its lock key and frozen migration checksums are unchanged. The earlier
[Flux DB cutover](https://github.com/odunboye/db/blob/main/MIGRATION.md) is still required if upgrading a
pre-Flux-DB database; this batch introduces no further database cutover.

## Build and verify

From the Flux root:

```sh
python3 tools/workspace.py check
pack --no-prompt install runtime
pack --no-prompt install iris-client
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

The browser closure now uses `iris-client`; `runtime`, `flux-protocol`,
`postgres`, `postgres-async`, and the DB/server packages remain forbidden
in that closure. Current package names/dependencies are checked in root CI.

Original subtree source names, source commits, historical reports and prior
migration records retain their original meaning. Original sibling repositories
and unrelated files are untouched. Old globally installed packages/build caches
may still exist outside this workspace; they are not compatibility packages
provided by this source tree.
