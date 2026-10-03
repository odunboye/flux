# Changelog

All notable changes to Flux UI are recorded here. The project follows Semantic
Versioning within the normal compatibility limits of a pre-1.0 release.

## Unreleased — runner lifecycle cleanup

- Canvas quit during event dispatch now removes listeners, overlay and generated
  styles, clears hit targets/capture and runs cooperative cleanup. Capacitor
  listener handles are retired even when registration resolves after shutdown.
- Terminal registers cooperative cleanup on its owner loop and runs it on quit
  or Ctrl+C; queued/late messages and commands after quit are ignored.
- Cleanup returned after a synchronous quit/suspend callback is discharged
  immediately instead of being retained on a retired runtime.
- Added Chromium teardown checks and terminal cancellation/PTY regressions.
- Raw Task/StreamTask IO remains non-preemptible; cooperative starters must return
  promptly. No new promise to forcibly cancel arbitrary IO is made.

## Unreleased — supported application guidance

- Added implemented architecture, runner capability matrix and links to evidence
  for specific guarantees; moved the historical proposal to `FUTURE_DESIGN.md`.
- Added a portable counter with terminal, DOM and Canvas entry points.
- Made the default executable a credential-free `UIApp` counter; preserved the
  old terminal agent under `examples/legacy-agent`.
- Marked compatibility/PAL APIs explicitly and documented terminal cancellation
  differences. Existing library APIs remain available.
- Corrected stale wrapping/scroll documentation to match implemented widgets.

## 0.4.0 — opt-in development DOM HMR

- Added `HotState` and `runWebHot` to `Flux.UI.Backend.Web.DOM.Run`.
- Explicit versioned state codecs reconstruct models across compiled bundles;
  incompatible or unsupported applications fall back to full reload.
- Hot disposal cancels managed effects, rejects stale callbacks, removes event
  listeners and retires timer/style resources. Restores do not replay init Cmds.
- Flux `dev --hot` (implies watch) and Chequra's in-memory state codec exercise
  the protocol. Normal `runWeb` and other backends remain unchanged.
- See [the HMR guide](../../design/DEV_HMR.md) for opt-in requirements and tests.

## Unreleased — private application inputs

- `sSecret` marks a `WInput` as a password: DOM uses `type=password`; terminal
  and canvas render masks without changing the underlying edit value.
- `Style` gains a trailing `secret : Bool`. Prefer `defaultStyle` and helpers;
  direct `MkStyle` callers must add the flag (normally `False`).
- The legacy shell HTTP effect is not suitable for credentials. Generated native
  RPC now uses the separate in-process `Flux.Platform.Client.Native` transport.

## 0.3.0-preview.1 — breaking Flux UI rename

- Renamed the implementation and public API to `flux-ui`, `Flux.UI.*`,
  `UIApp` and `UIColor`; removed the old package and namespace entirely.
- Renamed native C symbols/libraries, browser hooks/hosts, examples, npm metadata
  and tooling overrides; internal backend event frames now use `f1`.
- Updated platform consumers, landing page and CI; added naming and native TUI
  regression coverage. No old-name wrappers or fallbacks are provided.
- See [MIGRATION.md](MIGRATION.md) before rebuilding applications.

## Earlier unreleased work (pre-rename record)

### Added

- Strict Web and Canvas Content Security Policy support using constructed
  stylesheets, with no generated style elements, style attributes, or inline
  scripts in the Todo browser and Capacitor hosts.
- General-purpose clipped scroll view and wrapped-text widgets across DOM,
  Canvas, and terminal renderers, including transformed Canvas hit testing.
- Cancellable browser HTTP retries with bounded exponential backoff.

### Changed

- Canvas no longer emits Todo-specific keyboard messages for touch gestures.

### Deprecated

- `Iris.Core.Widget` compatibility model and `Iris.Core.Runtime.run`; use
  `Iris.Widget`, `Iris.App.IrisApp`, and a specialized backend runner.

## 0.2.0-preview.1 — 2026-09-11

### Added

- Complete versioned platform-event wire protocol and validation.
- Typed DOM and Canvas event integration.
- Lifecycle-aware cancellable commands and stale callback protection.
- Canvas responsive layout, multi-pointer capture, safe areas, minimum touch
  targets, and semantic native-control overlay.
- Typed browser routing, validated UTF-8 URL encoding/decoding, explicit
  not-found results, base paths, and navigation guards.
- Browser HTTP cancellation, timeout, and response-size limits.
- Playwright integration tests and portable release validation.

### Changed

- DOM controls use delegated events instead of inline handlers.
- Unchanged DOM output no longer replaces native nodes each frame.

### Migration

- Long-running browser effects should use `CancellableTask`; legacy `Task` and
  `StreamTask` cannot stop their underlying operation.
- New applications should use `Iris.Widget` and specialized runners rather
  than the legacy `Iris.Core.Widget`/`Iris.Core.Runtime` path.

## 0.1.0

- Initial TUI framework and Web/Canvas foundation.
