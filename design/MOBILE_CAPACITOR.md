# Optional Capacitor integration

This covers Flux's own application-packaging/build CLI for Capacitor targets
(`flux mobile *`). The `Iris.Mobile` library itself (Capacitor command/
subscription bindings, native session persistence) lives in
[odunboye/iris](https://github.com/odunboye/iris) - see its
[mobile library guide](https://github.com/odunboye/iris/blob/main/mobile/README.md).

## Architecture

```
Application (Chequra)
    -> Iris.Mobile commands / owned subscriptions
    -> capacitor 0.3 typed bindings + one registered JS bridge
    -> Capacitor 8.4.3
    -> iOS / Android WebView
```

No second native bridge or new renderer is introduced. Flux core/server packages
remain independent of Capacitor. The existing DOM UI and CSS are packaged as local
assets; native plugins are bundled before the compiled application. There is no
remote `server.url`, storage snapshot, watcher injection or automatic RPC replay.

`iris-mobile` is an optional external package outside the ordinary workspace
map (same as `capacitor` itself), pinned at the commit recorded in
`workspace.json`'s `external_packages.iris-client` note. `flux mobile compile`
adds it, `iris-client` and `capacitor` in a **temporary** Pack map derived
from the application's existing local map; ordinary `pack.toml` files and server
dependency registrations are not rewritten. Prefer a separate mobile UI ipkg if
only the mobile target imports `Iris.Mobile`.

## Configuration

Add `flux.mobile.json` beside an application's `flux.json` (or pass an explicit
`--config FILE` for a disposable packaging experiment):

```json
{
  "format": 1,
  "appId": "com.example.sandbox",
  "appName": "Sandbox App",
  "capacitor": "/path/to/capacitor",
  "webDir": "public",
  "entry": "build/exec/my-app.js",
  "ui": "mobile.ipkg",
  "assets": ["index.html", "*.css", "assets/*.png", "assets/*.svg"]
}
```

For networked applications, use `"format": 2` and add an explicit
`"apiOrigin": "https://your-api.example.com"`. This is an origin, not a route:
no HTTP, userinfo, path/trailing slash, query, fragment or noncanonical default
port. There is no insecure loopback exception. Format 1 remains a packaging-only
preview and cannot initialize `Iris.Mobile.Client.mobileClient`.

Format 2 requires exactly one CSP meta element with `default-src 'self'`,
`script-src 'self'`, `object-src 'none'`, `base-uri 'none'` and `form-action 'none'`.
The explicit format-2 opt-in binds `connect-src` to only the configured HTTPS API;
other directives are preserved, and duplicate directives/script overrides are
rejected. Runtime configuration is immutable and initializes before the app.

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
flux mobile setup --capacitor /path/to/capacitor
flux mobile check --capacitor /path/to/capacitor

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

The ordinary Chequra web entry uses a relative API origin. Networked mobile apps
must use a separate entry calling `Iris.Mobile.Client.mobileClient`, with explicit
format-2 configuration and server origin/CORS policy - see iris-mobile's own
README for the transport's guarantees (origin binding, no redirects/cookies/
retries, bounded streaming) and native session persistence. Hosted deployment
remains separate work. No hosted backend or payment/card service is created by
this integration.

Camera, biometrics, app lifecycle/back/deep-link plugin bindings,
notifications, permission flows and device accessibility testing are subsequent
capabilities—not implied by the five existing plugins. One-shot cancellation
suppresses delivery but cannot undo a started native action. Monitoring restarts
must be explicit and must not replay writes.

## Tests

```sh
python3 -m unittest discover -s tools -p 'test_mobile*.py'
flux mobile check --capacitor /path/to/capacitor
```

`flux mobile check` builds and runs iris-mobile's own compiled-Idris adapter
test against the hardened bridge (fetching
[odunboye/iris](https://github.com/odunboye/iris) at the pinned commit) -
see `tools/mobile_check.py`. For a packaged release's bundled web content:

```sh
node /path/to/iris/mobile/tests/browser.cjs /path/to/mobile/releases/ID
```

For actual native vault behavior, with the SDK runtimes already installed:

```sh
python3 packages/mobile/tests/native_probe.py --capacitor /path/to/capacitor
```

This creates new scratch devices/apps, never uses existing user devices, and
removes its fixtures and forwards. The iOS 26.5 Simulator probe uses local ad-hoc
signing (unsigned apps cannot be assumed to access Keychain). Android 14/API 34
uses a disposable emulator with its own system PIN; that OS version requires a
secure screen lock for unlocked-device keys. Tests cover cold persistence,
origin isolation, native revision CAS/clear, reinstall reset, and Android
ciphertext/AAD tampering, corrupt data, and locked-device denial. This is not a
physical-device or biometric certification. SDK caches remain as normal. This
test drives real packaging through `flux mobile build/sync`, so it stays here
rather than moving to iris with the library it exercises.

Pinned core/native/CLI 8.4.3 deliberately avoids the current 8.5.x CLI's vulnerable
xcode/uuid dependency. Library, example and Flux mobile tooling npm audits all
reported zero vulnerabilities during validation; rerun audits as advisories change.
