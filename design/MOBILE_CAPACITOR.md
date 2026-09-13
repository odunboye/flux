# Optional Capacitor integration

## Architecture

```
Application (Chequra)
    -> Flux.Mobile commands / owned subscriptions
    -> idris2-capacitor 0.2 typed bindings + one registered JS bridge
    -> Capacitor 8.4.3
    -> iOS / Android WebView
```

No second native bridge or new renderer is introduced. Flux core/server packages
remain independent of Capacitor. The existing DOM UI and CSS are packaged as local
assets; native plugins are bundled before the compiled application. There is no
remote `server.url`, storage snapshot, watcher injection or automatic RPC replay.

`flux-mobile` is an optional package outside the ordinary workspace map.
`flux mobile compile` adds it and `capacitor` in a **temporary** Pack map derived
from the application's existing local map; ordinary `pack.toml` files and server
dependency registrations are not rewritten. Prefer a separate mobile UI ipkg if
only the mobile target imports `Flux.Mobile`.

## Configuration

Add `flux.mobile.json` beside an application's `flux.json` (or pass an explicit
`--config FILE` for a disposable packaging experiment):

```json
{
  "format": 1,
  "appId": "com.example.sandbox",
  "appName": "Sandbox App",
  "capacitor": "/path/to/idris2-capacitor",
  "webDir": "public",
  "entry": "build/exec/my-app.js",
  "ui": "mobile.ipkg",
  "assets": ["index.html", "*.css", "assets/*.png", "assets/*.svg"]
}
```

`ui` is optional and otherwise comes from `flux.json`. Other keys are required;
unknown and duplicate keys are rejected. Paths resolve relative to `--project`,
even with an external config file. `entry` is a compiled, standalone Idris browser
program. `webDir/index.html` must have exactly one `<script src="app.js"></script>`
(or its module equivalent); packaging replaces it with the bundled module entry.
Public assets are an explicit allowlist of non-recursive globs. JavaScript source,
JSON/private metadata, hidden files, symlinks and escaping paths are not copied as
public assets. The compiled entry is supplied separately. Native identity changes
are refused once a host exists; migration requires deliberate host management.

## Commands

```sh
flux mobile setup --capacitor /path/to/idris2-capacitor
flux mobile check --capacitor /path/to/idris2-capacitor

flux mobile compile --project /path/to/app
flux mobile build --project /path/to/app
flux mobile sync ios --project /path/to/app
flux mobile sync android --project /path/to/app
flux mobile open ios --project /path/to/app
flux mobile run android --project /path/to/app
```

`flux --project /path/to/app mobile build` also works. Setup is explicit and runs
locked npm installs for the library and Flux tooling, without package lifecycle
scripts. No ordinary Flux command installs mobile dependencies. Compile only
builds the selected UI target; run ordinary schema generation/server checks as
needed. Build only packages assets; it does not install an app or start a database.

Sync creates/updates the owned Capacitor host and performs an explicit locked npm
install there. Open/run first sync, then delegate to the pinned local Capacitor
CLI. Native SDK/network/build effects are not transactional or rolled back by an
asset rollback. Projects and outputs are retained for inspection.

The preview tooling supports macOS/Linux, Node 22+, npm and Pack. iOS requires
macOS/Xcode; Android requires its SDK and a compatible JDK (JDK 21 was validated).
Signing, deployment targets, permissions, privacy manifests, release identities
and store submission are application responsibilities.

## Ownership and publication

- `.workspace/mobile/owner.json` binds output ownership to the project.
- Builds use frozen input snapshots and fresh staging directories. Successful
  bundles publish to immutable `releases/<id>` directories with file hashes and
  a source/configuration fingerprint in `build.json`.
- Failure leaves the previous build pointer intact; temporary stages clean up.
- Sync rejects stale sources/configuration and tampered releases, including
  directory symlinks. Unknown output/native-host directories are never adopted.
- An OS-backed project lock prevents concurrent CLI operations. Compiler/bundler/
  SDK subprocesses have owned process groups; failure, timeout and interruption
  stop those groups before releasing the lock. Shared SDK daemons are not owned.
- Native projects live in `.workspace/mobile/native/{ios,android}`. Their source
  files are not regenerated wholesale. Managed npm files/configuration cannot be
  silently overwritten; the owned web tree is staged before replacement.

Checkouts, compiler output and installed dependencies are trusted build inputs.
Hashes detect local release modification; they are not code signing or a complete
supply-chain attestation. The compiler/dependency caches remain Pack's concern.

## Chequra validation and remaining work

Chequra was packaged using an external temporary config, without changing its
source, authentication, ledger schema or ordinary web/server configuration.
Its bundled UI boots in Chromium with registered plugins, and both native projects
sync successfully. Unsigned iOS Simulator Debug and Android Debug APK builds pass.
These are packaging/build checks, **not device-level behavioral certification**.

The current Chequra entry still uses a relative API origin. In a native WebView
that points at local assets, not the hosted financial API. Before enabling native
sign-in, add an explicit HTTPS API endpoint, appropriate server origin/CORS policy
and CSP, plus secure session persistence and lifecycle handling. Never rewrite
requests or weaken CSP silently in the packager. No hosted backend or payment/card
service was created by this integration.

Secure storage, camera, biometrics, app lifecycle/back/deep-link plugin bindings,
notifications, permission flows and device accessibility testing are subsequent
capabilities—not implied by the five existing plugins. One-shot cancellation
suppresses delivery but cannot undo a started native action. Monitoring restarts
must be explicit and must not replay writes.

## Tests

```sh
python3 -m unittest discover -s tools -p test_mobile.py
flux mobile check --capacitor /path/to/idris2-capacitor
node packages/mobile/tests/browser.cjs /path/to/mobile/releases/ID
```

The library separately tests compiled Idris against actual browser plugins.
Pinned core/native/CLI 8.4.3 deliberately avoids the current 8.5.x CLI's vulnerable
xcode/uuid dependency. Library, example and Flux mobile tooling npm audits all
reported zero vulnerabilities during validation; rerun audits as advisories change.
