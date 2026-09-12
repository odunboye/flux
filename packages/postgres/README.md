# flux-postgres

A PostgreSQL client for Idris2, implemented from scratch against the
[Postgres wire protocol](https://www.postgresql.org/docs/current/protocol.html)
over TCP sockets — no `libpq`. Deadline-aware native transport uses a small C
bridge; authenticated TLS uses OpenSSL 3 through that same bridge. Build prerequisites:
a C11 compiler, `make`, `pkg-config`, and OpenSSL 3 headers/libraries
(`brew install openssl@3 pkg-config` on macOS; `libssl-dev pkg-config` on Debian).
Deployments must also provide OpenSSL 3 shared libraries and their intended CA trust.

Package: `flux-postgres`; public modules such as `Idris2_pg` and `Data.PGTypes`
remain unchanged. Pooling is provided by `flux-postgres-pool`. See the
[package migration](../../design/PACKAGE_MIGRATION.md).

## Project goals

The following proof-branch discussion is historical context from the original
transport repository, not a verification claim about this Flux checkout.

The main goal of this project is a **fully verified** Postgres client: one
where Idris2's dependent types are used to *prove* protocol-level
correctness properties at compile time, not just exercise them with tests —
an encode/decode pair proven to round-trip, a connection state machine the
compiler actually enforces rather than only labels, length-indexed buffers
that turn a short read or a frame overrun into a type error instead of a
runtime one, and so on. That work happens on the
[`verified`](https://github.com/odunboye/idris2-pg/tree/verified) branch,
and is meant as a demonstration of what dependent types buy you in a real,
non-toy client for a real wire protocol, not a toy example.

This `main` branch is the practical first step toward that goal: a
**usable**, thoroughly tested (unit tests plus a live end-to-end CRUD suite —
see "Running the tests" below) client, built first to have a working,
protocol-correct reference implementation before attempting to formally
prove anything about it. Everything documented below describes this branch;
it remains useful in its own right — including as the reference the
`verified` branch's proofs get checked against — independent of how far that
work progresses.

## Install / build

Requires [pack](https://github.com/stefan-hoeck/idris2-pack).

```sh
pack install flux-postgres
```

Or, from the Flux repository root:

```sh
pack build packages/postgres/flux-postgres.ipkg
```

## Usage

```idris
import Idris2_pg
import Data.PGTypes
import Data.PGValue

main : IO ()
main = do
  let cfg = mkPGConfig "127.0.0.1" 5432 "myuser" "mypassword" "mydb"
  Right db <- connectDB cfg
    | Left err => putStrLn (displayError err)

  -- INSERT/UPDATE/DELETE/DDL - parameters are sent via the extended query
  -- protocol, never string-interpolated into the SQL.
  Right _ <- execCommand db
    "INSERT INTO users (name, email) VALUES ($1, $2)"
    [Just "Ada", Just "ada@example.com"]
    | Left err => putStrLn (displayError err)

  -- SELECT
  Right rows <- queryRows db "SELECT name, email FROM users" []
    | Left err => putStrLn (displayError err)
  traverse_ (\row => case (getText row "name", getText row "email") of
                           (Right name, Right email) => putStrLn (name ++ " <" ++ email ++ ">")
                           _ => pure ())
            rows

  -- Transactions
  _ <- withTransaction db $ do
         _ <- execCommand db "UPDATE accounts SET balance = balance - 100 WHERE id = $1" [Just "1"]
         execCommand db "UPDATE accounts SET balance = balance + 100 WHERE id = $1" [Just "2"]

  closeDB db
```

For commands that must reject SQL batches **before any side effect**, use
`execCommandPrepared db sql params`. It always uses Parse/Bind/Execute, including
when `params` is empty. `execCommand`/`queryRows` retain their simple-protocol
fast path for zero-parameter calls; their result-count check is not a
pre-execution SQL safety boundary. Flux DB migrations use the strict prepared
command API.

See `test/src/Main.idr` for a fuller worked example (CRUD, transactions,
`execMulti`, `cancelQuery`, array/date/timestamp/numeric values, NULL
handling).

This library is deliberately just the wire-protocol client: connect/query/
execute, the value getters below, transactions, LISTEN/NOTIFY, COPY, and
TLS - nothing that maps a `Row` onto an application record type. That
layer - `Row`<->record derivation, generated CRUD, a typed query builder -
lives in [Flux DB](../db), built on top of
this client (and meant to grow support for other DB clients later, not
stay flux-postgres-specific forever).

### Value decoding

`Data.PGValue` decodes a `Row`'s columns on demand: `getText`, `getInt`,
`getInteger` (arbitrary precision), `getDouble`, `getBool`,
`getDate`/`getTimestamp` (`PGDate`/`PGTimestamp` records),
`getArray`/`getArray2D`/`getNestedArray` (Postgres arrays of any
dimensionality, via the `PGArrayValue` tree for anything beyond 2D), and
`getJSON` (`json`/`jsonb` columns, via a small dependency-free JSON parser
in `Data.PGJson` — no external JSON library needed).

`queryRows` returns text-format columns (the default). `queryRowsBinary`
requests binary format for every column instead; `getInt`/`getInteger`/
`getBool`/`getDouble`/`getText` understand both formats transparently
(binary floats are decoded via a from-scratch, verified-against-reference-values
IEEE754 implementation in `Data.PGBinary`, since Idris2 has no 32-bit-float
primitive to lean on). The other accessors (`getDate`/`getTimestamp`/
`getArray*`/`getJSON`) only support text format. Binary mode is opt-in and
less safe than text: unlike text parsing, a type mismatch (e.g. calling
`getDouble` on a binary `int4` column) isn't guaranteed to fail cleanly,
since binary formats don't self-describe their type the way text does.
Binary-format parameter *sending* isn't implemented — parameters are
always sent as text, which Postgres accepts and casts correctly for every
type.

### Timeouts

`PGConfig` has `connectTimeoutMs`/`readTimeoutMs : Maybe Nat` fields, both
`Nothing` (block indefinitely, the old behavior) by default via
`mkPGConfig`; set them with record update syntax, e.g.
`{ readTimeoutMs := Just 5000 } cfg`. `connectTimeoutMs` bounds `connectDB`
(the TCP connect plus the auth handshake) and `cancelQuery`'s own
out-of-band connection; `readTimeoutMs` bounds any single call that waits
on the server (`execCommand`/`queryRows`/`queryRowsBinary`/`execMulti`,
`waitForNotification`, `copyOut`/`copyIn`).

Network waits now use nonblocking sockets and `poll` with an absolute
monotonic deadline, through a native library built automatically by the
package prebuild. No query is forked and abandoned when its caller times out.
A read timeout or transport/protocol failure closes and marks the `DB`
unusable; subsequent operations reject that handle. `closeDB` is idempotent.
Nested deadlines keep the earlier deadline. Both raw and TLS record IO use
this transport.

A deadline does not forcibly interrupt arbitrary CPU work or the platform's
hostname resolver. Such work stays owned until it returns. Use numeric
addresses when resolver latency must be avoided. Chez's blocking foreign
calls permit collection; managed byte buffers are pinned until those calls
return, as required by the [Chez foreign interface](https://cisco.github.io/ChezScheme/csug10.1.0/csug.pdf).

### Exclusive connection pooling

The optional `async/flux-postgres-pool.ipkg` package exports `Data.PGPool` for
`flux-runtime`. Defaults are 8 connections, 128 queued acquirers, and a 5-second
acquisition deadline. Connections are opened lazily. Missing transport
limits become 5 seconds for connection setup and 30 seconds per operation.
Cold connection setup is serialized per pool to avoid concurrent SCRAM
allocation contention; established connections execute independently.

Use `withConnection pool callback` in a task, or `withConnectionIO` within
an existing blocking worker. One callback owns its connection for its whole
lifetime, including transactions. Cancellation joins the worker before
returning the lease. Do not retain the supplied DB or fork work that uses it.
Timed-out connections and connections left in a transaction are discarded.
`closePool` rejects new leases and closes idle connections; active leases
close when their callback finishes. `poolClosed` observes completion.

`Flux.DB.Pool.pooledRepository` reuses this pattern for CRUD; use
`withPooledTransactionRepos` when several repositories must share a single
transactional lease.

### TLS

`useTLS = True` now **requires authenticated TLS 1.3** before sending startup
or authentication messages. OpenSSL 3 validates the certificate chain, validity,
server purpose, SAN hostname/IP, CertificateVerify signature and Finished.
There is no encrypted-but-unverified mode, TLS 1.2 fallback or plaintext fallback.
The old hand-written handshake/record implementation is no longer a connection
backend; retained crypto/vector modules do not authenticate network sessions.

```idris
let cfg : PGConfig
    cfg = { useTLS := True,
            tlsCAFile := Just "/run/secrets/postgres-ca.pem",
            connectTimeoutMs := Just 5000, readTimeoutMs := Just 2000 } $
      mkPGConfig "db.example.com" 5432 "app" password "tasks"
```

`tlsCAFile = Nothing` uses OpenSSL's default trust paths, including deployment
`SSL_CERT_FILE`/`SSL_CERT_DIR` overrides. `Just path` loads **only** that PEM CA
file, with no system-trust fallback. A missing/invalid file fails closed; empty
paths and NUL-containing paths/hosts are rejected. A CA file with `useTLS=False`
is an error. `mkPGConfig` still defaults to plaintext for local development:
**explicitly enable TLS for remote/production connections.** The driver does not
itself read libpq environment variables.

Identity always comes from `PGConfig.host`: DNS names use SAN dNSName and SNI;
numeric addresses require SAN iPAddress and send no SNI. Common-name-only certs
and partial-label wildcards are rejected. Provision SAN certificates and the
proper trust bundle rather than bypassing verification. Chain depth is capped at
8 intermediates and certificate-list size at 256 KiB. No client certificate/mTLS
or automatic online revocation checking is provided.

The same thread-owned monotonic deadline spans TCP, SSLRequest, TLS and startup;
record I/O uses the existing nonblocking/poll transport. Cancellation connections
independently revalidate identity. Timeouts poison the main connection and free
TLS state before closing the fd; cleanup never waits for a peer close_notify.
As with DNS/CPU work, trust-file access and cryptographic work are synchronous,
not forcibly preempted: elapsed deadlines are checked rather than abandoning a
worker. Configure finite connect/read deadlines for production.

This is a security-breaking cutover: `MkPGConfig` has a new final
`Maybe String` CA-file field; prefer `mkPGConfig` plus record updates.
Low-level `connectPG`/`tlsClientHandshake` now require trust/identity arguments.
Self-signed/CN-only servers accepted by the former implementation will fail.

Authenticated integration (from the workspace root, owned disposable database):

```sh
touch packages/postgres/flux-postgres.ipkg  # pack tracks Idris/manifest timestamps, not C
pack --no-prompt install flux-postgres
pack --no-prompt build packages/postgres/test/tls-identity.ipkg
python3 packages/postgres/test/tls_identity_test.py
```

This exercises trusted DNS/IP chains, SNI, untrusted/incomplete/expired/future/
wrong-purpose/mismatched certificates, SAN rules, missing/exclusive CA files, downgrade
refusal, deadlines, SCRAM, large payloads, cancellation and connection cleanup.
The root workspace integration gate runs it too. `--native-only` runs just the
C bridge peer matrix without an Idris compiler or database; it is not a substitute
for the full integration suite.

### Errors

Every fallible call returns `Either PGError a`, where `PGError` is one of
`ConnectionError` (transport-level), `ProtocolError` (an unexpected/malformed
response), or `SqlError Error` (a genuine error from the server — inspect it
with `message`, `detail`, `hint`, `schemaName`, `tableName`, `columnName`,
`constraintName`, etc.). `displayError` renders any of them as a message.

## Running the tests

Unit tests (codec + value parsers, no database needed):

```sh
cd test
pack build unit-test.ipkg
./build/exec/flux-postgres-unit-test
```

Property-based tests ([idris2-hedgehog](https://github.com/stefan-hoeck/idris2-hedgehog),
no database needed): round-trip pairs (codecs, base64, AEAD encrypt/decrypt)
and algebraic invariants (X25519/P-256 Diffie-Hellman agreement symmetry)
generalized over random input, rather than the fixed examples/RFC vectors
the unit tests use. See `test/src/PropTests.idr` for what's covered and
what's deliberately out of scope.

```sh
cd test
pack build prop-test.ipkg
./build/exec/flux-postgres-prop-test
```

CRUD smoke test (needs a real Postgres — connection details come from
`PG_TEST_HOST`/`PG_TEST_PORT`/`PG_TEST_USER`/`PG_TEST_PASSWORD`/`PG_TEST_DB`,
defaulting to `127.0.0.1:5432`/`testuser`/`testpass`/`testdb`). A plain
default Postgres container already works, since SCRAM-SHA-256 (the
out-of-the-box default) is supported:

```sh
docker run -d --name flux-postgres-test \
  -e POSTGRES_USER=testuser -e POSTGRES_PASSWORD=testpass -e POSTGRES_DB=testdb \
  -p 5432:5432 postgres:16

cd test
pack build test.ipkg
./build/exec/flux-postgres-test
```

To exercise the MD5 path instead (also supported, but not the default since
Postgres 14), force `md5` password storage first:

```sh
docker run -d --name flux-postgres-test-md5 \
  -e POSTGRES_USER=testuser -e POSTGRES_PASSWORD=testpass -e POSTGRES_DB=testdb \
  -e POSTGRES_HOST_AUTH_METHOD=md5 -p 5432:5432 postgres:16

psql -h 127.0.0.1 -U testuser -d testdb -c "ALTER SYSTEM SET password_encryption = 'md5';"
psql -h 127.0.0.1 -U testuser -d testdb -c "SELECT pg_reload_conf();"
psql -h 127.0.0.1 -U testuser -d testdb -c "ALTER USER testuser WITH PASSWORD 'testpass';"
```

The smoke test's `testTLS` step exercises a real TLS 1.3 handshake if (and
only if) the server it connects to has SSL enabled - against a plain
`postgres:16` container (SSL off by default), it prints `SKIP TLS: server
does not have SSL enabled` rather than failing. To actually exercise it,
enable SSL on the container first (a self-signed cert generated and
installed at its default `ssl_ecdh_curve=prime256v1` - no special
configuration needed, since that's what this client negotiates by
default - see "TLS" above):

```sh
docker exec flux-postgres-test bash -c '
  cd "$(psql -U testuser -d testdb -tAc "show data_directory;")"
  openssl req -new -x509 -days 365 -nodes -out server.crt -keyout server.key -subj "/CN=localhost"
  chmod 600 server.key
  chown postgres:postgres server.key server.crt
'
psql -h 127.0.0.1 -U testuser -d testdb -c "ALTER SYSTEM SET ssl = on;"
docker restart flux-postgres-test
```

CI (`.github/workflows/ci.yml`) runs the unit tests, the property-based
tests, and both smoke test variants (SCRAM and MD5) on every push/PR; TLS
is not yet part of that
matrix (setting up SSL on a GitHub Actions service container needs
filesystem access this project hasn't wired into CI yet - see above for
running it manually) but is fully covered by the unit tests plus manual
live testing as described here.

## Features

- [x] Startup + MD5/cleartext/trust password authentication
- [x] Simple and extended (parameterized) query protocols
- [x] CREATE/SELECT/INSERT/UPDATE/DELETE/DROP, multi-statement batches (`execMulti`)
- [x] Transactions (`beginTx`/`commitTx`/`rollbackTx`/`withTransaction`, `txStatus`)
- [x] Query cancellation (`cancelQuery`)
- [x] NOTIFY payload decoding (see `Data.PGTypes.Notification`)
- [x] Value decoding: text/int/bool/double/arbitrary-precision integer/date/timestamp/array of any dimensionality/JSON (see "Value decoding" above)
- [x] Prepared statement caching — a query text is Parsed once per
      connection and reused on repeat calls (see `DB.stmtCache`).
- [x] Binary format for results (`queryRowsBinary`) — see "Value decoding"
      above for what's covered and its caveats. Sending binary-format
      parameters isn't implemented; parameters are always sent as text.
- [x] The `COPY` protocol (`copyOut`/`copyIn`) — bulk export/import via
      `COPY ... TO STDOUT`/`COPY ... FROM STDIN`, text format. `copyIn`
      sends the whole payload as a single CopyData message rather than
      chunking it.
- [x] SCRAM-SHA-256 auth — Postgres 14+'s default for new roles, built
      entirely from scratch (`Crypto.SHA256`, `Crypto.SCRAM`: HMAC-SHA256,
      PBKDF2, base64, the full RFC 5802 handshake including verifying the
      server's final signature). The client nonce comes from `contrib`'s
      `System.Random` (Chez's standard PRNG) - fine here since the nonce
      only needs to be unique, not secret, per RFC 5802. No channel binding
      (`SCRAM-SHA-256-PLUS`) yet - that would tie into the TLS handshake's
      exporter data, which is a natural follow-up now that TLS exists but
      hasn't been built.
- [x] LISTEN/NOTIFY (`listenChannel`/`unlistenChannel`/`waitForNotification`)
      — use a connection dedicated to listening, since `waitForNotification`
      blocks it until a notification arrives; it can't run other queries
      meanwhile; that wait can be bounded with `readTimeoutMs` (see
      "Timeouts" above).
- [x] Read/connect timeouts (`PGConfig.connectTimeoutMs`/`readTimeoutMs`) —
      deadline-aware native socket waits with no abandoned query threads;
      see "Timeouts" above for exactly what that does and
      doesn't bound.
- [x] TLS 1.3 (`PGConfig.useTLS`) — the full handshake and record layer,
      built entirely from scratch: X25519 *and* P-256 ECDHE
      (`Crypto.Curve25519`/`Crypto.P256`), ChaCha20-Poly1305
      (`Crypto.ChaCha20`/`Crypto.Poly1305`/`Crypto.ChaCha20Poly1305`), the
      HKDF-based key schedule (`Crypto.HKDF`), and the handshake state
      machine (`Network.TLS`/`Network.TLSHandshake`/`Network.TLSWire`).
      See "TLS" above for what this does and doesn't protect against, and
      why P-256 (not X25519) is what's actually negotiated on the wire.
