module Models


import Data.PGValue
import Flux.DB.Derive.ActiveRecord
import Flux.DB.ObjectFromJSON

import JSON.Simple.Derive


%default covering
%language ElabReflection


--------------------------------------------------------------------------------
-- Model
--------------------------------------------------------------------------------

public export
record Todo where
  constructor MkTodo
  id    : Integer
  title : String
  done  : Bool

-- The real Postgres table is `todos` (plural), but the Idris type is
-- `Todo` (singular) - Table's default naming (exact-lowercase of the
-- type name) would get this wrong, so the override is required here,
-- not optional; this is also the concrete case flux-db's
-- table-naming override mechanism exists to prove actually works, not
-- just typecheck. `[("done", "false")]` is flux-db's take on Drift's
-- `withDefault()` - a real DB-level `DEFAULT false` on the generated
-- `createTableSql` (used by `Main.idr`/`test/src/Main.idr` below,
-- replacing what used to be a hand-written DDL string here). This
-- isn't load-bearing for `createTodo` itself, which always supplies
-- `done` explicitly via `NewTodo` - that's this codebase's existing
-- equivalent of Drift's *other* option, `clientDefault()`, an
-- application-side default needing no DB schema support at all - kept
-- here anyway to preserve the exact schema this table already had, and
-- to demonstrate `columnDefaults` is real, not just documented.
TodoTable : DeriveItem
TodoTable = customTable Export (Just "todos") Nothing [("done", "false")]

%runElab derive "Todo" [ToJSON, FromJSON, Eq, Show, FromRow, ToRow, TodoTable]

-- `deriveInsertable` auto-generates `NewTodo`/`MkNewTodo` (every field
-- of `Todo` except `id`), its `ToRow` instance, and the
-- `Insertable NewTodo Todo` link - no hand-written companion record
-- needed. `createTodo` below uses `MkNewTodo`/`insert` exactly as if
-- this had been declared by hand.
%runElab deriveInsertable Nothing "Todo"

-- `deriveSubset` + `ObjectFromJSON` (in place of json-simple's own
-- `FromJSON`) auto-generates `NewTodoBody`/`MkNewTodoBody` (just
-- `title`) and decodes it as a plain `{"title":"..."}` object -
-- json-simple's own `FromJSON` derive would instead treat this
-- single-field record as a "newtype" and (de)serialize it as the bare
-- value `"Buy milk"`, not `{"title":"Buy milk"}` (see
-- `ObjectFromJSON`'s own doc comment for why, confirmed directly against
-- this exact library version). This used to be a hand-rolled parser
-- (`parseNewTodo`, decoding into `json-simple`'s generic `JSON` value
-- and pulling `"title"` out manually) purely to route around that.
%runElab deriveSubset ["title"] "NewTodoBody" [ObjectFromJSON] "Todo"

-- `deriveSubset` auto-generates `TodoUpdate`/`MkTodoUpdate` (only the
-- listed fields of `Todo`, not "every field except one" the way
-- `deriveInsertable` above works) plus its `FromJSON` instance -
-- deliberately an include-list here, not `id` minus an exclude-list:
-- the PUT body's accepted fields are an HTTP-API decision, not a
-- database one, and shouldn't silently grow if `Todo` ever gains a
-- server-only column later.
%runElab deriveSubset ["title", "done"] "TodoUpdate" [FromJSON] "Todo"

-- `deriveColumns` auto-generates `TodoColumns`/`MkTodoColumns`/
-- `todoColumns` (fields `id`/`title`/`done`, each `Column Todo _`) - the
-- typed column references `Handlers.TypedQuery`'s handlers build
-- `Flux.DB.Query` conditions/orderings from (`todoColumns.id ==. tid`,
-- `orderByAsc todoColumns.id`).
%runElab deriveColumns "Todo"
