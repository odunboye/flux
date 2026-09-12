# Iris

Iris is an experimental cross-platform declarative UI framework for Idris 2.
Applications describe a pure model/update/view loop and render through terminal,
Web DOM, or HTML Canvas/Capacitor backends.

> **Release status:** `v0.2.0-preview.1`. The TUI and Web foundations are
> usable previews. Capacitor bundles are portable and tested in browsers, but
> native store releases still require platform-specific device validation.

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
- Cancellable lifecycle-aware effects
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
git clone <repository-url> iris
cd iris
idris2 --install iris.ipkg
```

## Minimal application

```idris
module Main

import Iris.App
import Iris.State.TEA
import Iris.Platform.Event
import Iris.Widget
import Iris.Backend.Web.DOM.Run

data Msg = Increment

update : Msg -> Nat -> (Nat, Cmd Msg)
update Increment count = (S count, none)

view : Nat -> Widget Msg
view count = vstack
  [ text ("Count: " ++ show count)
  , button "Increment" Increment
  ]

app : IrisApp Nat Msg
app = MkApp (0, none) update view (\_, _ => Nothing) Nothing

main : IO ()
main = runWeb app
```

Use `Iris.Backend.Terminal.Run.runTUI` or
`Iris.Backend.Canvas.Run.runCanvas` for another supported backend.

## Build and test

```bash
make build          # build Iris
make test           # Idris test suites
make check          # tests, web/mobile bundles, release validation

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
build machines:

```bash
make native-check
# or
./scripts/validate-native.sh ios
./scripts/validate-native.sh android
```

See [`WEB_MOBILE_COMPLETION.md`](WEB_MOBILE_COMPLETION.md) for the complete
release checklist.

## Supported scope

| Target | Status |
|---|---|
| Terminal/TUI | Functional flagship backend |
| Web DOM | Supported preview |
| Canvas/Capacitor WebView | Supported preview; native certification required |
| SDL2 desktop | Experimental skeleton |
| Embedded framebuffer | Experimental skeleton |
| Native mobile renderer | Deferred; Capacitor uses the Canvas/WebView target |

Known limitations include general-purpose Canvas wrapping/scroll containers,
strict CSP without inline styles, and native-device validation. The legacy
`Iris.Core.Widget`/`Iris.Core.Runtime` path is retained for compatibility; new
applications should use `Iris.Widget` and the specialized runners.

See [`API_STABILITY.md`](API_STABILITY.md), [`SECURITY.md`](SECURITY.md), and
[`CHANGELOG.md`](CHANGELOG.md) before deploying.

## License

MIT — see [`LICENSE`](LICENSE).
