# Flux Mobile (optional preview)

`Chequra → Flux.Mobile → idris2-capacitor → Capacitor`.

This package adapts the existing typed library; it does not implement a second
JavaScript/native bridge or replace the DOM/Canvas renderer. It is intentionally
outside the default workspace dependency map so server and ordinary browser
builds do not install Capacitor. Requires `capacitor >= 0.3.0` and `iris >= 0.4.0`.

## Use

Import `Flux.Mobile`. The module exposes plugin option/result types and named
Flux commands: `toastCommand`, `alertCommand`, `confirmCommand`, `promptCommand`,
`actionSheetCommand`, `networkStatusCommand`, `deviceInfoCommand`,
`batteryInfoCommand`, and `deviceIdCommand`.

```idris
-- Message constructor: NetworkLoaded : Either MobileError NetworkStatus -> Msg
networkStatusCommand NetworkLoaded
-- One-shot init command with owned ongoing callbacks:
networkChanges NetworkLoaded
-- Alternatively, for TEA App's subscription API:
networkSubscription "mobile-network" NetworkLoaded
```

`perform` adapts a typed `Async JS [JSErr] a` plugin operation into a
`CancellableTask`. Errors are messages. Operations are invoked once, with no
retry/resume replay. Cancellation suppresses late results but **cannot undo an
already-started native operation**. It must never be used to imply that a
payment/dialog/permission request was rolled back.

Network listeners are removed on cancellation, including registration races.
Flux's runtime cancels effects on pause/shutdown and compatible HMR disposal.
Applications must explicitly re-establish desired monitoring on resume; this
must not replay one-shot commands. The adapter also gates error/event delivery
after disposal. The current upstream async-js runner prints a completion message
to the console for each finished command; it does not shut down the Flux app.

The bundled Capacitor registration must load before the application. Installing
the Idris package alone does not register native JavaScript plugins.

## Origin-bound RPC

`Flux.Mobile.Client.mobileClient` constructs a client only when a format-2 mobile
bundle provides an explicit canonical HTTPS `apiOrigin`. It never falls back to
the WebView origin. POSTs are restricted to that origin's `/rpc/v1/` routes;
redirects, cookies, caches, unsupported headers and automatic retries are disabled.
Responses are bounded while streaming, and cancellation suppresses late delivery.
Use this transport for mobile authentication and ledger RPC, not native HTTP
plugins which bypass browser origin policy.

## Native sessions (flux-mobile 0.2 / capacitor 0.3)

`Flux.Mobile.Session` supplies `openSessionCommand`, `readSessionCommand`,
`saveSessionCommand`, `clearSessionCommand` and a strict token/intent codec.
No account metadata is stored. Use the portable read-only `Auth.me` command to
validate identity after reading an active token, then fetch current account data.
A `RevokingSession` is durable logout intent: never use it to authenticate a UI
session and never replay remote revocation without an explicit user action.

Vault writes use native revision CAS. Clearing rotates the revision; cancellation
and timeouts cannot undo a save already in progress. Re-read after uncertain saves
instead of resubmitting credentials. A native storage failure is an error, not
permission to fall back to Preferences or browser storage. Only actual web mode
returns `Nothing` (an explicitly memory-only preview).

`mobile sync` snapshots the library's local native plugin, installs it into an
owned host, and sets Capacitor `loggingBehavior: 'none'`. The vault refuses access
with bridge logging enabled because SDK debug logs can expose payloads. Modified
managed dependency files are rejected rather than silently adopted.

The optional `tests/native_probe.py` runs actual vault operations on new owned
iOS Simulator/Android emulator instances. It requires installed SDK runtimes,
Node 22+, Xcode on macOS for iOS, and Java 21 for Android. It does not use or wipe
existing devices, contacts no API, and removes its scratch devices/apps afterward.
Physical-device, biometric and full application lifecycle validation remain separate.

## Packaging and CLI

See the [mobile integration design](../../design/MOBILE_CAPACITOR.md).
`flux mobile setup/check/compile/build/sync/open/run` provide opt-in tooling and
owned application releases without changing the normal workspace map.

## Verification

From the Flux root:

```sh
python3 tools/mobile_check.py --capacitor /path/to/idris2-capacitor
```

This creates a temporary Pack dependency map, builds the **compiled Idris**
adapter test and runs it against the hardened bridge with mocked SDK plugins.
It verifies typed errors, JSON marshalling, no retries, suppression of cancelled
results and idempotent listener disposal. It does not modify `pack.toml` or add
Capacitor to any server package. Build outputs remain ignored under `build/`.

Native permissions, biometrics, camera, dedicated app lifecycle/deep-link plugins
and deployment signing remain separate work. Native persistence does not imply
biometric authorization or complete physical-device validation.
