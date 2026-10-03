# Supported runner capabilities

Flux UI 0.4.x provides preview runners, not equal feature coverage on every
platform. Share `UIApp` and `Widget`; select behavior using this matrix.

| Capability | DOM (`runWeb`) | Terminal (`runTUI`) | Canvas / WebView (`runCanvas`, `runMobile`) |
|---|---|---|---|
| Controls | Semantic text, buttons, inputs, checkboxes, progress | ANSI-rendered widgets; keyboard application input | Painted widgets with native-control overlay |
| Layout | Browser CSS, stacks, wrapped text and scroll widgets | Character-cell layout, wrapping and clipped scroll offsets | Cell-metric layout, wrapping and clipped scroll offsets |
| Scrolling | Browser scroll container | Application controls offsets | Application controls offsets; not a general native scroll system |
| Keyboard/text | Native browser input, composition and typed key events | Terminal key events; application handles editing/activation | Native overlay input, composition and typed key events |
| Pointer | Browser controls and typed pointer events | No portable pointer-control interaction promised | Hit testing, pointer capture, clipped/transformed targets |
| Focus | Native focus with restoration across render | Application-defined input handling; no DOM-style focus guarantee | Overlay restores active control and selection |
| Accessibility | Semantic controls, names, progress/status semantics | Terminal output; no screen-reader widget semantics contract | Semantic controls in DOM overlay; richer labeling metadata remains limited |
| Effect lifecycle | Managed `CancellableTask` cleanup on pause/quit; stale callbacks rejected | Cooperative cleanup on quit/Ctrl+C; starters register on the owner loop | Managed cleanup on pause/quit; quit removes overlay, listeners and generated stylesheet |
| Raw `Task`/`StreamTask` | Cannot forcibly interrupt arbitrary IO | Cannot forcibly interrupt or promise joining arbitrary IO | Cannot forcibly interrupt arbitrary IO |
| Navigation | Browser history/location events and router helpers | Application-defined navigation | Browser/WebView location events; device back behavior needs validation |
| Hot replacement | Opt-in `runWebHot` with explicit state codec | Not supported | Not supported |
| Release evidence | Idris checks and Chromium acceptance | Idris rendering checks and pseudo-terminal smoke | Idris checks and Chromium acceptance; native device certification separate |

SDL2 desktop and embedded framebuffer are experimental skeletons. Native GPU
mobile rendering is deferred. Capacitor hosts the Canvas/WebView runner; it does
not establish a separate native-widget renderer.

## Evidence and boundaries

[Architecture](ARCHITECTURE.md#guarantees-and-evidence) maps claims to implementation
and tests. [The release checklist](WEB_MOBILE_COMPLETION.md) describes portable CI
and native checks. Browser tests cover specific input, focus and history cases;
they do not certify every browser, assistive technology or native device.

Wrapped text and clipped scroll widgets are implemented, including Canvas hit
coordinate transforms. This is narrower than a general scrolling/layout engine:
applications manage offsets on terminal/Canvas. Canvas expands hit targets to
minimum touch dimensions without reflowing neighbors: leave adequate spacing
between controls (the counter uses padded buttons). Rich layout constraints are
not proved by the widget type. Backend styling can differ.

`UIApp` does not accept `Sub`; `State.TEA.App` and its subscription field belong
to the legacy runtime. Use commands, `handleEvent` and `tickMsg` in new apps.

Cooperative starters must return promptly with a cleanup action after arranging
asynchronous work. Terminal registers these on the owner loop; arbitrary raw IO
still cannot be forcibly interrupted or promised joined. Cleanup runs once on
normal quit or Ctrl+C. Callback delivery during or after cancellation is ignored.
