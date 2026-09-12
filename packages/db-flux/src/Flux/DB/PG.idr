||| Glue between Flux's `AppProg`/`AppError` and idris2-pg's `PGError` -
||| lifts any `IO (Either PGError a)` call (a raw `queryRows`/
||| `execCommand`, or any of idris2-pg's `Flux.DB.Crud` generic CRUD
||| calls - `insert`/`findById`/`update`/`deleteById` - they all share
||| this exact shape) into a Flux handler, throwing a `500 AppError` on
||| failure.
|||
||| This has nothing app-specific in it - no schema, no routes, no
||| handlers - it's the same handful of lines every Flux app backed by
||| idris2-pg would otherwise hand-write itself. `todo-api`
||| (`apps/todo-api` in this workspace) is `flux-db`'s first real
||| consumer; this module exists so the second one doesn't have to
||| re-derive it.
module Flux.DB.PG

import public Flux.Core.Middleware
import public Flux.Core.Router
import public Idris2_pg
import public Data.PGTypes
import Data.PGValue
import Flux.DB.Row

%default covering

||| Logs `msg` to stderr and throws a generic, stable `500 AppError` -
||| the shared "don't leak internals to the client" policy every
||| failure path in this module (`dbFail`, `decodeRows`, `decodeOne`)
||| goes through, so a SQL error and a row-decode error are redacted the
||| same way.
logAndFail500 : String -> AppProg a
logAndFail500 msg = do
  liftIO (stderrLn msg)
  throw (MkAppError 500 "internal server error")

||| Any PG-side failure (connection, protocol, or SQL) becomes a plain
||| 500 with a generic, stable public message - the real error (which
||| can name real tables/columns/constraints, or echo back a value from
||| the failed query, e.g. a unique-constraint violation) is logged to
||| stderr instead of handed to the client. An app that wants to
||| distinguish e.g. a unique-constraint violation (400) from a genuine
||| connection loss (500) can inspect idris2-pg's `SqlError`'s raw
||| Postgres error fields (`Data.PGTypes`) itself and throw a more
||| specific `AppError` instead of using this.
export
dbFail : PGError -> AppProg a
dbFail err = logAndFail500 "db error: \{displayError err}"

||| Lifts any idris2-pg call into a Flux handler: runs it on the bounded blocking worker pool,
||| throwing `dbFail err` on `Left err`, returning the value on `Right`.
||| Every idris2-pg call - `queryRows`, `execCommand`, and all of
||| `Flux.DB.Crud`'s generic CRUD helpers - shares this exact
||| `IO (Either PGError a)` shape, so this one combinator covers all of
||| them; a handler writes `todo <- dbIO (insert {a=Todo} db newTodo)`
||| instead of hand-matching `Right`/`Left` itself.
export
dbIO : IO (Either PGError a) -> AppProg a
dbIO action = do
  Right result <- blocking action
    | Left _ => throw (MkAppError 503 "database worker queue unavailable")
  Right v <- pure result
    | Left err => dbFail err
  pure v

||| Convenience wrapper for a raw `SELECT`, for the cases that don't fit
||| `Flux.DB.Crud`'s generic, single-row-by-id-shaped helpers (a list
||| result, custom ordering/filtering, a join, etc).
export
query : DB -> String -> List (Maybe String) -> AppProg (List Row)
query db sql params = dbIO (queryRows db sql params)

||| Convenience wrapper for a raw `INSERT`/`UPDATE`/`DELETE`/DDL
||| statement, for the cases that don't fit `Flux.DB.Crud`'s generic
||| `insert`/`update`/`deleteById` (a non-replace mutation, DDL, a
||| statement touching more than one table, etc). Discards the command
||| tag `execCommand` itself returns - use `dbIO (execCommand ...)`
||| directly if you need it.
export
command : DB -> String -> List (Maybe String) -> AppProg ()
command db sql params = ignore (dbIO (execCommand db sql params))

||| Decodes every row via `FromRow`, throwing a `500 AppError` if any
||| row fails to decode - a malformed row means something's
||| inconsistent between the schema and the type (a column renamed on
||| one side but not the other, say), not a client mistake, so this
||| isn't a `400`. The decode error itself (which can echo back raw
||| column values) is logged to stderr, not handed to the client - same
||| redaction policy as `dbFail`, so a SQL error and a row-decode error
||| look identical from the outside.
export
decodeRows : FromRow a => List Row -> AppProg (List a)
decodeRows rows = case traverse fromRow rows of
  Right vs => pure vs
  Left err => logAndFail500 "row decode error: \{err}"

||| As `decodeRows`, for a query expected to return at most one row (an
||| `UPDATE`/`INSERT` `RETURNING`, say). `[]` decodes to `Nothing`, not
||| an error - an empty result is client-caused (e.g. "no row with that
||| id"), not a decode failure.
export
decodeOne : FromRow a => List Row -> AppProg (Maybe a)
decodeOne []       = pure Nothing
decodeOne (r :: _) = case fromRow r of
  Right v  => pure (Just v)
  Left err => logAndFail500 "row decode error: \{err}"

||| The largest value a Postgres `BIGINT`/`BIGSERIAL` column can hold.
||| `requireIntParam` rejects anything above this with a `400` instead
||| of passing it through to the database, where an out-of-range
||| `bigint` input fails as a genuine SQL error - an opaque `500`, not a
||| client-caused `400`, for what's really still a malformed request.
bigintMax : Integer
bigintMax = 9223372036854775807

||| Reads and parses a positive-integer path param, failing with `400`
||| if it's missing, isn't a plain non-negative integer (no sign, no
||| decimal point - a Postgres `SERIAL`/`BIGSERIAL` id never needs
||| either), or exceeds `bigintMax`.
export
requireIntParam : (name : String) -> Context -> AppProg Integer
requireIntParam name ctx = case getParam name ctx.pathParams of
  Just s => case all isDigit (unpack s) && s /= "" of
    False => throw (MkAppError 400 "invalid \{name}")
    True  =>
      let n := the Integer (cast s)
       in if n <= bigintMax
             then pure n
             else throw (MkAppError 400 "\{name} is out of range")
  Nothing => throw (MkAppError 400 "missing \{name}")

||| `requireIntParam` for the path param named `"id"` - matching
||| `Table`'s own default primary-key column-name convention
||| (`Flux.DB.Derive.ActiveRecord`), and Flux's own routing convention of
||| naming that path segment `:id`.
export
requireId : Context -> AppProg Integer
requireId = requireIntParam "id"
