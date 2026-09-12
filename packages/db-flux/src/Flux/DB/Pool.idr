module Flux.DB.Pool

import public Data.PGPool
import Flux.DB.Query
import Flux.DB.Repository
import Flux.DB.Crud
import Flux.DB.Field
import Flux.DB.Row
import Flux.DB.Table
import Idris2_pg

%default covering

||| Each independent repository operation borrows one exclusive connection.
||| Use withPooledTransactionRepos when several operations must share a lease.
export
pooledRepository : (Table a, FromRow a, ToRow a, Insertable ins a, ToRow ins, ToField pk)
                => Pool -> Repository pk a ins
pooledRepository pool = MkRepository
  { findById = \key => withConnectionIO pool (\db => (pgRepository {a} {ins} {pk} db).findById key)
  , insert = \value => withConnectionIO pool (\db => (pgRepository {a} {ins} {pk} db).insert value)
  , update = \value => withConnectionIO pool (\db => (pgRepository {a} {ins} {pk} db).update value)
  , deleteById = \key => withConnectionIO pool (\db => (pgRepository {a} {ins} {pk} db).deleteById key)
  , query = \query => withConnectionIO pool (\db => (pgRepository {a} {ins} {pk} db).query query)
  }

export
withPooledTransactionRepos : Pool -> (DB -> repos) -> (repos -> IO (Either PGError a)) -> IO (Either PGError a)
withPooledTransactionRepos pool makeRepos action =
  withConnectionIO pool (\db => withTransactionRepos db makeRepos action)
