# Flux Mobile (optional preview)

`Chequra → Flux.Mobile → idris2-capacitor → Capacitor`.

This package adapts the existing typed library; it does not implement a second
JavaScript/native bridge or replace the DOM/Canvas renderer. It is intentionally
outside the default workspace dependency map so server and ordinary browser
builds do not install Capacitor. Requires `capacitor >= 0.2.0` and `flux-ui >= 0.3.0`.

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

Native permissions, secure storage, biometrics, camera, app lifecycle/deep-link
plugins and deployment signing are not implemented by this initial adapter.
