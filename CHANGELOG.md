# Changelog

All notable changes to Iris are recorded here. The project follows Semantic
Versioning within the normal compatibility limits of a pre-1.0 release.

## Unreleased

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
