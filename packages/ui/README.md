# Flux UI

Flux UI is an experimental cross-platform declarative UI framework for Idris 2.
Applications describe a pure model/update/view loop and render through terminal,
Web DOM, or HTML Canvas/Capacitor backends.

> **Release status:** `0.4.x` preview APIs. The TUI and Web foundations are
> usable previews. Capacitor bundles are portable and tested in browsers, but
> native store releases still require platform-specific device validation.

## Minimal application

```idris
module Main

import Flux.UI
import Flux.UI.Backend.Web.DOM.Run

data Msg = Increment

update : Msg -> Nat -> (Nat, Cmd Msg)
update Increment count = (S count, none)

view : Nat -> Widget Msg
view count = vstack
  [ text ("Count: " ++ show count)
  , button "Increment" Increment
  ]

app : UIApp Nat Msg
app = MkApp (0, none) update view (\_, _ => Nothing) Nothing

main : IO ()
main = runWeb app
```

Use `Flux.UI.Backend.Terminal.Run.runTUI` or
`Flux.UI.Backend.Canvas.Run.runCanvas` for another supported backend.

The complete [counter example](examples/counter/README.md) supplies terminal,
DOM and Canvas entry points, package files and browser hosts.

## Features

- Elm-style typed state updates and effects
- Platform-independent widget tree
- ANSI terminal, semantic DOM, and Canvas renderers
- Versioned keyboard, pointer, scroll, viewport, composition, lifecycle, and
  navigation events
- Responsive Canvas layout, hit testing, multi-pointer capture, safe areas,
  clipping, and a screen-reader/native-input overlay
- Typed routing with UTF-8 URLs, path/query parameters, base paths, guards, and
  browser history
- Cooperative lifecycle-aware browser effects (terminal behavior differs)
- Browser HTTP cancellation, timeouts, and response limits
- Idris unit tests and Playwright browser integration tests

## Requirements

- Idris 2 `0.8.x`
- `make`
- Node.js `20.x` for browser tests and Capacitor tooling
- A C compiler for the terminal support library

Native validation additionally requires Xcode and/or the Android SDK.

## Install

```bash
# From the Flux repository root, using its pinned pack collection:
pack --no-prompt install flux-ui
```

This is an outright rename, not an alias package. See
[the breaking migration guide](MIGRATION.md) for source, DOM, FFI and event-wire
changes. Rebuild existing applications; old and new bundles must not be mixed.

## Build and test

For the complete root CI suite, install Chromium under `packages/ui` and run
`bash tools/ci-suite.sh ui` from the Flux root. For individual targets, select
the pinned compiler/package environment first:

```bash
# From the Flux root, after installing flux-ui:
compiler=$(pack app-path idris2)
export PATH="$(dirname "$compiler"):$PATH"
export IDRIS2_PACKAGE_PATH="$(pack package-path)"
export IDRIS2_LIBS="$(pack libs-path)"
cd packages/ui
make build          # build Flux UI
make test           # Idris test suites
make check          # tests, web/mobile bundles, release validation
make -C examples/todo build-terminal
python3 tests/native_smoke.py  # both native TUI entries, FFI and keyboard shutdown

npm ci
npx playwright install chromium
make browser-test   # real Chromium integration tests
```

The Todo example can be run from `examples/todo`:

```bash
make terminal
make web
make mobile-preview
```

## Capacitor validation

Portable bundle validation is included in `make check`. On provisioned native
build machines, run from `packages/ui` with the same compiler environment:

```bash
make native-check
# or
./scripts/validate-native.sh ios
./scripts/validate-native.sh android
```

See [`WEB_MOBILE_COMPLETION.md`](WEB_MOBILE_COMPLETION.md) for the complete
release checklist.

## Supported scope

See [the capability matrix](CAPABILITIES.md) for controls, layout, input, focus,
accessibility, cancellation and lifecycle differences, and
[the implemented architecture](ARCHITECTURE.md) for the application contract.


| Target | Status |
|---|---|
| Terminal/TUI | Functional flagship backend |
| Web DOM | Supported preview |
| Canvas/Capacitor WebView | Supported preview; native certification required |
| SDL2 desktop | Experimental skeleton |
| Embedded framebuffer | Experimental skeleton |
| Native mobile renderer | Deferred; Capacitor uses the Canvas/WebView target |

Wrapped text and clipped scroll-offset widgets are implemented. General native
Canvas scrolling, richer accessibility metadata and native-device validation
remain limited. Terminal effect cleanup differs from browser cleanup. The legacy
`Flux.UI.Core.Widget`/`Flux.UI.Core.Runtime` path is retained for compatibility; new
applications should use `Flux.UI.Widget` and the specialized runners.

See [`API_STABILITY.md`](API_STABILITY.md), [`SECURITY.md`](SECURITY.md), and
[`CHANGELOG.md`](CHANGELOG.md) before deploying.

## License

MIT — see [`LICENSE`](LICENSE).
