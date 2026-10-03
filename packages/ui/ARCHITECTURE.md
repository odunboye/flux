# Flux UI implemented architecture

Start with [the runnable counter](examples/counter/README.md). The supported
application surface is exported by `import Flux.UI`; choose a runner explicitly.
The [capability matrix](CAPABILITIES.md) defines backend differences.

```text
UIApp: init + update + view + handleEvent + tickMsg
                         |
                 Flux.UI.Widget
                         |
         Terminal.Run / Web.DOM.Run / Canvas.Run
```

## Application contract

`UIApp model msg` holds an initial model and commands, a pure update function,
a pure view returning `Widget msg`, an event-to-message callback and an optional
tick message. `Cmd msg` describes effects whose results use the application's
message type. A runner interprets commands and dispatches input and effect
messages through update before rendering the next view.

Share model/update/view between targets. Keep platform transports and entry
points explicit; a shared widget tree does not imply identical pixels, input
behavior or cancellation across runners. `Sub` and the older `State.TEA.App`
record are compatibility APIs, not the subscription contract of `UIApp`.

## Implemented paths

- Terminal: `Backend.Terminal.Run` renders the supported widget tree through
  `WidgetRender` and the ANSI/FFI terminal layer.
- DOM: `Backend.Web.DOM.Run` uses semantic HTML rendering, browser event queues
  and managed effect lifecycle handling. `runWebHot` adds opt-in versioned model
  reconstruction; see [HMR](../../design/DEV_HMR.md).
- Canvas: `Backend.Canvas.Run` uses cell-based layout, painting and transformed
  hit targets. A semantic DOM overlay supplies native controls and text entry.
  `runMobile` is this Canvas path with mobile metrics, hosted in a WebView.

The specialized runners are the implementation reference. The generic
`Core.Runtime`, `Core.Widget` and old `Backend.Web.DOM` PAL adapter are retained
compatibility paths. SDL2, framebuffer and the generic PAL do not provide
supported application runners. See [API policy](API_STABILITY.md).

## Guarantees and evidence

| Property | Mechanism and evidence | Limit |
|---|---|---|
| Application message types | `UIApp model msg`, `Widget msg`, `Cmd msg`; [PublicAPITest](tests/PublicAPITest.idr) | Does not prove business logic or rendering correct |
| Event boundary validation | Versioned decoder; [EventWireTest](tests/EventWireTest.idr) | Internal protocol, not arbitrary network input validation |
| Browser effect retirement | Managed generations and cleanup; [RuntimeTest](tests/RuntimeTest.idr), browser acceptance | Cooperative work only; terminal differs and Canvas Quit teardown has a known gap |
| Canvas hit targets and layout | [CanvasLayoutTest](tests/CanvasLayoutTest.idr) | Concrete tested cases, not a general layout proof |
| DOM escaping and semantics | [DOMRenderTest](tests/DOMRenderTest.idr), [browser tests](tests/browser/flux-ui.spec.js) | No complete accessibility certification |
| Terminal startup and exit | [native smoke checks](tests/native_smoke.py) | No guarantee that arbitrary effect IO is joined |

Types enforce the relationships encoded in their definitions. They do not
establish blanket layout validity, absence of leaks, or freedom from runtime
failure. For example, `IRGB Nat Nat Nat` documents 0–255 channels without encoding
that bound; layout dimensions and offsets require application judgment.

Run `bash tools/ci-suite.sh ui` from the Flux root with the documented
prerequisites to exercise the supported suite. Future GPU/resource proofs,
desktop/embedded backends and wider architectural proposals live in
[FUTURE_DESIGN.md](FUTURE_DESIGN.md); they are not release commitments.
