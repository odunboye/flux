# Reviewed private-task cutover (migration 3)

This is a breaking cutover for the **Flux Todo starter**, not an automatic
conversion of the legacy `examples/todo-api` or protocol smoke examples.

## Frozen history and data policy

- Migration 1 (`create todos`) and migration 2 (`accounts and revocable sessions`)
  keep their exact SQL, names and checksums. Do not edit either applied migration.
- Migration 3 atomically renames `todos` to `todos_anonymous_archive`, then creates
  `private_todos` and its `(owner_id,id)` index. The private table has a non-null
  account foreign key, a separate BIGSERIAL sequence and bounded titles.
- The original table, rows, IDs, constraints and sequence remain in the archive.
  **No anonymous row is assigned to a registrant, deleted or exposed by an API.**
  Accounts and existing valid sessions survive the migration.
- New task IDs belong to the new table. Do not treat old anonymous IDs as private
  task identifiers. No automatic adoption/import operation is supplied.

## Operator procedure

1. Stop old API processes and migration runners. Use a dedicated database; back
   it up and independently verify restoration before a non-disposable cutover.
2. Review the three migrations in `Main.idr` and frozen `authSchemaV1`. Inspect
   `flux_db_meta.migrations`, the anonymous row count and existing schema names.
   An existing archive/private table is a conflict to investigate, not to drop.
3. Build the new server/UI together and run `./flux migrate` (or the corresponding
   `--project` command). The reviewed runner locks migration execution and commits
   this migration with its history row. Errors stop startup; there is no fallback
   to public handlers or partial adoption.
4. Verify all original rows are in `todos_anonymous_archive`, `private_todos` is
   initially empty, old history rows are unchanged and version 3 is recorded.
   Verify two accounts cannot read or mutate each other's tasks before serving.
5. Run only the new binaries. Keep the archive backed up and outside HTTP serving.
   If adoption is needed later, review an explicit owner mapping/import, including
   new-ID mapping and an audit trail. Do not blindly assign all rows to one user.

There is no automatic rollback, archive deletion or schema planner. Recovery is
an operator-reviewed roll-forward or a verified restore with all writers stopped.
Do not rename the archive back while a private application is running.

## Authorization semantics

All six starter task methods require a verified bearer session. Every read and
mutation derives owner from the server principal; get/update/toggle/delete bind
both owner and task ID in the same statement. Lists and their 51-row lookahead
bind owner too. A foreign-owned ID behaves like a nonexistent ID. A forged cursor
can skip the caller's own rows but cannot read another owner's rows. Pagination
is keyset-based, not a multi-request snapshot.

Already authenticated/admitted requests may finish during revocation. Logout is
not transaction cancellation, and a lost response does not prove a write failed.
The UI clears identity-bound state immediately and ignores old-session replies;
it never automatically retries writes. Production HTTPS, remote verified PG TLS,
backup/restore, edge rate limits and deployment operations remain prerequisites.
