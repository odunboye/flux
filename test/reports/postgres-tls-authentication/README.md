# Authenticated PostgreSQL TLS — 2026-09-12

## Change

The connection-facing custom TLS implementation is replaced by OpenSSL 3. TLS
1.3, certificate chain/validity/server purpose, SAN DNS/IP, CertificateVerify and
Finished verification are mandatory. DNS uses SNI; IP identities require IP SANs.
CN-only and partial-label wildcard identities are rejected. No plaintext, old TLS
version, system-trust-after-explicit-CA-error, or unverified fallback exists.

`PGConfig.tlsCAFile` selects an exclusive PEM CA bundle, or `Nothing` selects
OpenSSL system trust. The application accepts `PGSSLMODE=verify-full` and optional
`PGSSLROOTCERT`; weaker/unknown modes and CA/plaintext conflicts fail closed.
Local-development defaults remain plaintext: remote users must enable TLS.

Native TLS BIO callbacks use the existing monotonic deadline socket functions,
inside collect-safe calls with managed buffers pinned. Session state is released
on failed startup/authentication, query invalidation, close and cancellation;
cleanup does not wait for close_notify. Cancellation obtains a fresh verified
connection. No worker is abandoned to simulate timeouts. Synchronous DNS, trust
file access and cryptographic work are not forcibly preempted; expiry is checked.

## Evidence

- **macOS ARM64, Idris 0.8.0 pinned pack compiler:** full **28/28** workspace
  integration steps passed, including real PostgreSQL, generated/native/browser
  clients, reviewed migrations, CRUD, fresh-copy CLI acceptance and landing.
- TLS identity suite: **18 peer/negotiation cases** covering trusted DNS/IP and
  SNI; untrusted/incomplete chains; missing CA file; explicit CA isolation despite
  default trust/SSL configuration; mismatched DNS/IP; expired,
  future, wrong-purpose, CN-only, DNS-as-IP and partial-wildcard certificates;
  TLS 1.2 rejection; SSL refusal/invalid response; and a stalled handshake.
  The 500ms handshake deadline closes and joins the peer (not a background worker).
- Real disposable PostgreSQL 16: verified TLS 1.3/SCRAM, exact large UTF-8 payload,
  cancellation (including rejecting an invalid trust file on the fresh cancel
  connection), 500ms read timeout, poisoning/reuse rejection and repeated close.
  Repeated for DNS, numeric IP and deployment default-trust-path configuration.
- Application TLS environment configuration connects to that real server and
  rejects six weaker/unknown/conflicting configurations.
- Existing standalone TLS deadline fixture passes with explicit trust and SANs.
- PostgreSQL unit/property executables, **28 tool tests**, **18 generator tests**,
  native runtime/PG ASan+UBSan regressions, ShellCheck and whitespace checks pass.
- **Local Docker Linux aarch64 / Debian 12 / OpenSSL 3.0:** C bridge builds with
  strict C11 warnings and passes the same **18 peer/negotiation cases**. This is
  specifically the native bridge probe, **not** an Idris/database Linux run.

The gate also forces native package refresh: pack otherwise ignores changed C
sources and even `pack install` can reuse a stale dylib. Refreshing the manifest
mtime before installation runs the native prebuild without changing source content.
The final executable's native library was checked for the new verification-policy
symbol, not just a successful Idris build.

Workspace source evidence: `.workspace/reports/20260912-134928/`. Selected logs
and machine-readable step results are copied here. Generated private keys and
CA material were temporary and were not retained. Disposable DB removal is
checked and includes anonymous volumes.

## Reproduce

From the repository root, with OpenSSL 3 development files, `pkg-config`, the
pinned pack compiler and Docker/PostgreSQL 16 available:

```sh
python3 tools/workspace.py check
python3 tools/workspace.py test
pack --no-prompt build packages/postgres/test/tls-deadline.ipkg
python3 packages/postgres/test/tls_deadline_test.py
```

For the Linux-native-only check, use a disposable Debian 12 container, install
`python3 openssl libssl-dev pkg-config gcc libc6-dev make ca-certificates`, copy
`packages/postgres/{Makefile,c,test/tls*.py}` into a temporary matching tree, then:

```sh
make native
python3 test/tls_identity_test.py --native-only
```

## Remaining scope

Hosted Linux CI/branch protection confirmation is still pending; the new full
TLS suite is wired into the platform workspace gate and CI installs OpenSSL
headers plus pkg-config. Local Docker evidence does not establish hosted CI.

No automatic online revocation, client-certificate authentication, durable
accounts/sessions, endpoint/row ownership, production deployment or backup/restore
is implemented here. Public task endpoints are still unsuitable for private
multi-user data. Retained hand-written crypto/vector modules are not an alternate
network TLS backend.
