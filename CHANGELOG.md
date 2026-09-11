# Changelog

All notable changes to Iris are recorded here. The project follows Semantic
Versioning within the normal compatibility limits of a pre-1.0 release.

## Unreleased

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
