# Web and hybrid-mobile release checklist

Iris has a tested Web DOM target and an HTML Canvas target suitable for a
Capacitor WebView. This checklist defines what is automated and what still
requires a machine with native SDKs.

## Portable validation

Run from the repository root:

```sh
make check
```

This command builds Iris, runs the EventWire/runtime/layout/router/DOM tests,
builds both Todo browser bundles, checks their JavaScript syntax and
entrypoints, validates the Capacitor configuration and shell, enforces a 5 MB
bundle limit, and rejects generated artifacts tracked by Git. Override the
size limit with `IRIS_MAX_BUNDLE_BYTES` when intentionally evaluating a larger
bundle.

CI runs the same command on every push and pull request, then installs
Playwright Chromium and runs real-browser integration tests. To run those
locally:

```sh
npm ci
npx playwright install chromium
make browser-test
```

## Implemented behavior

- One `IrisApp` model/update/view API across terminal, DOM, and Canvas.
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
Xcode or the Android SDK installed:

```sh
cd examples/todo
make build-mobile
cd mobile
npm ci
npx cap sync ios       # macOS + Xcode
npx cap sync android   # Android SDK/Studio
```

Then build and smoke-test the generated projects. Confirm startup, rotation,
background/resume, hardware back behavior, multi-touch pointer IDs, safe-area
appearance, and offline loading. Signing and store packaging remain deployment
responsibilities.

## Known limitations

- The Canvas semantic overlay exposes standard controls, but complex input
  features such as validation descriptions and application-defined checkbox
  labels require richer widget metadata in a future API revision.
- Canvas stack layout is cell-based and does not yet provide general wrapping
  or scroll-container semantics.
- Active IO cannot be forcibly cancelled by generic `Cmd`; late deliveries are
  suppressed after shutdown, while pause/resume cancellation remains
  effect-specific.
- Desktop SDL2 and embedded framebuffer modules are experimental skeletons and
  are not covered by this release checklist.
