module Data.PGRepository

import Idris2_pg
import Data.PGTypes
import Data.PGField
import Data.PGRow
import Data.PGTable
import Data.PGQuery
import Data.PGCrud as Crud

%default total

||| A generic CRUD + typed-query repository for `a`, bound to one `DB`
||| connection - a plain record of functions (not an interface), so a
||| caller is handed exactly the implementation it needs explicitly (a
||| real Postgres-backed one via `pgRepository`, or an app's own
||| in-memory test double of the same shape) rather than relying on
||| Idris2's global instance search - the same function-field-in-a-
||| record shape Flux's own `Route`/`App` records already use in
||| production (`handler : h`, `onError : ErrorRenderer`).
|||
||| Deliberately HTTP-independent: every operation returns a plain
||| `IO (Either PGError _)`, no `Context`/status codes/`AppProg` - a
||| handler decides what a `Nothing`/`False`/`Left` becomes (a 404, a
||| 500, ...). `Nebula.PG.dbIO` already lifts any of these into
||| `AppProg` unchanged, the same way it already lifts `Data.PGCrud`'s
||| own functions - no nebula-flux changes needed for this.
|||
||| `pk` is generic (matching `Data.PGCrud.findById`/`deleteById`'s own
||| genericity over the same name) - any type with a `ToField` instance
||| works (`Data.PGField` already has one for `String`, so a UUID/slug
||| primary key stored as text works today with no new code needed
||| anywhere underneath this). Most apps still use `Integer`
||| (`SERIAL`/`BIGSERIAL`) - `nebula-flux`'s `requireId` stays
||| `Integer`-only for exactly that reason, not generalized speculatively
||| ahead of a real non-`Integer`-keyed consumer; an app that needs one
||| reads its own path param as whatever type it needs and calls
||| `repo.findById`/`repo.deleteById` directly, no nebula-flux change
||| required for that to already work.
public export
record Repository pk a ins where
  constructor MkRepository
  findById   : pk -> IO (Either PGError (Maybe a))
  insert     : ins -> IO (Either PGError a)
  update     : a -> IO (Either PGError (Maybe a))
  deleteById : pk -> IO (Either PGError Bool)
  query      : Query a -> IO (Either PGError (List a))

||| The default, real implementation: every operation delegates straight
||| to `Data.PGCrud`'s generic CRUD helpers and `Data.PGQuery.selectQuery`,
||| all bound to `db`. Free once a type has the `Table`/`FromRow`/`ToRow`/
||| `Insertable ins a` instances `%runElab derive [...]` already
||| generates - nothing repository-specific to derive.
|||
||| `Data.PGCrud` is imported qualified (`as Crud`) here specifically
||| because it exports top-level `findById`/`insert`/`update`/
||| `deleteById`, and `Repository` above declares fields with those
||| exact same names - real record-field accessors join a namespaced
||| overload set, so this might resolve unqualified via Idris2's
||| ambiguity elaboration too, but relying on that is unnecessary risk;
||| the qualified import costs nothing and is already this codebase's
||| own idiom for the identical situation elsewhere.
export
pgRepository : (Table a, FromRow a, ToRow a, Insertable ins a, ToRow ins, ToField pk) => DB -> Repository pk a ins
pgRepository db = MkRepository
  { findById   = Crud.findById {a} db
  , insert     = Crud.insert {a} db
  , update     = Crud.update db
  , deleteById = Crud.deleteById {a} db
  , query      = selectQuery {a} db
  }

||| Runs `action` inside a Postgres transaction (idris2-pg's own
||| `withTransaction` - BEGIN, then COMMIT on `Right`/ROLLBACK on `Left`,
||| no nesting), handing it repositories built via `mkRepos` from the
||| SAME transactional `db` - the one connection the whole transaction
||| runs on. This is the scoped-ownership contract: `action` should only
||| use repositories THIS call handed it (via `mkRepos`), not ones built
||| earlier from a different `db` (or the same `db` outside the
||| transaction) - there's no way to enforce that at the type level (a
||| repository is just a value, not tied to "this transaction" in its
||| own type), so this exists to make the natural way to write the call
||| also the correct one. `repos` is deliberately unconstrained - a
||| single repository, a tuple of several, or a record grouping many -
||| `mkRepos` decides the shape.
export covering
withTransactionRepos : DB -> (DB -> repos) -> (repos -> IO (Either PGError a)) -> IO (Either PGError a)
withTransactionRepos db mkRepos action = withTransaction db (action (mkRepos db))
