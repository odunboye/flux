# Web and hybrid-mobile release checklist

Flux UI has a tested Web DOM target and an HTML Canvas target suitable for a
Capacitor WebView. This checklist defines what is automated and what still
requires a machine with native SDKs.

## Portable validation

Run from the Flux repository root:

```sh
(cd packages/ui && npm ci && npx playwright install chromium)
bash tools/ci-suite.sh ui
```

This command builds Flux UI, runs the public API/EventWire/runtime/layout/router/DOM/HTTP tests,
builds both Todo browser bundles, checks their JavaScript syntax and
entrypoints, validates the Capacitor configuration and shell, enforces a 5 MB
bundle limit, and rejects generated artifacts tracked by Git. Override the
size limit with `FLUX_UI_MAX_BUNDLE_BYTES` when intentionally evaluating a larger
bundle.

The suite also checks the public API on Node, builds the separate web entry,
checks both native TUI entries' startup/keyboard shutdown in pseudo-terminals,
and runs real-browser integration tests. The root Linux CI job provisions the
same suite. To rerun only the browser tests after building:

```sh
make -C packages/ui browser-test
```

## Implemented behavior

- One `UIApp` model/update/view API across terminal, DOM, and Canvas.
- Versioned and validated platform events for keyboard, pointer, wheel,
  viewport, focus, orientation, lifecycle, composition, and browser location.
- Ordered DOM and Canvas queues with idempotent listener installation.
- Shutdown-safe command and streaming-message delivery.
- Canvas button/checkbox hit testing with pointer capture and responsive
  relayout from the measured viewport.
- Typed route serialization, path parameters, validated UTF-8 query parsing,
  fragments, browser history commands, and deep-link startup events.
- Semantic DOM controls, accessible names, focus-visible styling, progress and
  status semantics, mobile touch sizing, and reduced-motion CSS.
- A synchronized native-control overlay for Canvas buttons, checkboxes, and
  text fields, providing keyboard focus, screen-reader semantics, mobile soft
  keyboard input, and model-driven text editing.
- Playwright coverage for DOM input/focus preservation, Canvas semantic text
  input, and browser-history lifecycle delivery.

## Native Capacitor validation

Native validation is intentionally not part of portable CI. On a machine with
Xcode or the Android SDK installed, after the portable bundle build above:

```sh
cd packages/ui/examples/todo/mobile
npm ci
# First-time setup: npx cap add ios / npx cap add android
npx cap sync ios       # macOS + Xcode
npx cap sync android   # Android SDK/Studio
```

The `v0.2.0-preview.1` release candidate was successfully compiled as an iOS
simulator Debug app and Android Debug APK on 2026-09-12. That pre-rename record
is **not validation of the Flux UI 0.3 rename**. Device-level behavior
must still be smoke-tested for startup, rotation, background/resume, hardware
back behavior, multi-touch pointer IDs, safe-area appearance, and offline
loading. Signing and store packaging remain deployment responsibilities.

## Known limitations

- The Canvas semantic overlay exposes standard controls, but complex input
  features such as validation descriptions and application-defined checkbox
  labels require richer widget metadata in a future API revision.
- Canvas stack layout is cell-based. Wrapped text and clipped scroll offsets
  are implemented; applications manage offsets rather than receiving a general
  native scrolling system.
- Managed `CancellableTask` effects are cancelled during lifecycle suspension and stale
  generation callbacks are rejected after resume. Canvas `QuitApp` can stop
  frame scheduling before teardown runs; see [capabilities](CAPABILITIES.md).
  Legacy `Task` actions cannot
  be forcibly interrupted; use `CancellableTask` for long-running production IO.
- Desktop SDL2 and embedded framebuffer modules are experimental skeletons and
  are not covered by this release checklist.

See [the capability matrix](CAPABILITIES.md) for terminal differences and
[the implemented architecture](ARCHITECTURE.md) for precisely scoped guarantees.
