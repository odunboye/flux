# Iris API and compatibility policy

Iris is currently `0.x`: minor releases may contain source-breaking changes,
but changes must include release notes and a migration path.

## Supported toolchain

- Idris 2: 0.8.x
- Node.js: 20.x for browser tests and Capacitor tooling
- Capacitor: 5.x in the Todo mobile example

CI is the source of truth for supported combinations.

## Stable application surface

`Iris.App.IrisApp`, `Iris.Widget`, `Iris.State.TEA.Cmd`, and
`Iris.Platform.Event` are the supported application API. The specialized
terminal, DOM, and Canvas runners are the supported runtimes.

`Iris.Core.Widget`, `Iris.Core.Runtime`, and the PAL adapter in
`Iris.Backend.Web.DOM` are legacy/experimental APIs. New applications should
not depend on them. They remain packaged for compatibility until a future
minor release can deprecate and remove them.

## EventWire guarantees

Wire payloads begin with a version field. Iris guarantees that:

- decoders reject unknown versions and malformed fields;
- existing tags keep their meaning for the lifetime of a protocol version;
- optional additions use new tags rather than changing existing field order;
- incompatible changes require a new version such as `i2`;
- decoders may enforce documented size and numeric limits.

The wire protocol is an internal backend boundary, not a public network
protocol. Persisted events must retain their protocol version.

## Deprecation process

A supported API must be marked deprecated for at least one minor release
before removal. `CHANGELOG.md` records additions, behavior changes,
deprecations, and migration instructions.
