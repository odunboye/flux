# Web and hybrid-mobile completion

The supported web and Canvas targets currently build through `examples/todo/make check`.

The remaining implementation milestone is the typed platform-event bridge:

1. Capture pointer, scroll, resize, focus, blur, and lifecycle events in the DOM and Canvas shells.
2. Encode events with a versioned tagged format rather than ad-hoc strings.
3. Decode and validate events before dispatching them through `EventApp`.
4. Test ordering, malformed payloads, multi-touch IDs, orientation changes, and background/resume behavior.
5. Validate Capacitor iOS and Android sync/builds on machines with the platform SDKs.

Existing `IrisApp` applications remain supported through the keyboard fallback in `Iris.App.Events`.
