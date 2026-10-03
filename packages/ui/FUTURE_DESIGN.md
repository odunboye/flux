# Flux UI — future design and historical architecture

> This is a historical design proposal, not a supported API or a correctness guarantee.
> Start with [the implemented architecture](ARCHITECTURE.md) and [capabilities](CAPABILITIES.md).
>
> A cross-platform declarative UI framework written in Idris2, targeting
> Web, Desktop, Mobile, Embedded, **and TUI (terminal)** from a single codebase.

---

## Table of Contents

1. [Vision & Goals](#1-vision--goals)
   - [Current Implementation Status](#current-implementation-status)
2. [What We Steal From Whom](#2-what-we-steal-from-whom)
3. [Why Idris2](#3-why-idris2)
4. [Layered Architecture Overview](#4-layered-architecture-overview)
5. [Module Structure](#5-module-structure)
6. [State Management — Enhanced TEA](#6-state-management--enhanced-tea)
7. [Widget System](#7-widget-system)
8. [Layout Engine](#8-layout-engine)
9. [Styling System](#9-styling-system)
10. [TUI Backend (Terminal UI)](#10-tui-backend-terminal-ui)
11. [Effect System](#10-effect-system)
12. [Rendering Pipeline](#11-rendering-pipeline)
13. [Platform Abstraction Layer (PAL)](#12-platform-abstraction-layer-pal)
14. [Platform Backends](#13-platform-backends)
15. [Animation System](#14-animation-system)
16. [Navigation & Routing](#15-navigation--routing)
17. [Theming & Design Tokens](#16-theming--design-tokens)
18. [Internationalisation (i18n)](#17-internationalisation-i18n)
19. [Accessibility](#18-accessibility)
20. [Developer Tooling](#19-developer-tooling)
21. [Build System & ipkg](#20-build-system--ipkg)
22. [Phased Roadmap](#21-phased-roadmap)
23. [Key Type Signatures (Preview)](#22-key-type-signatures-preview)

---

## 1. Vision & Goals

| Goal                        | Description                                                           |
| --------------------------- | --------------------------------------------------------------------- |
| **Single source of truth**  | One Idris2 codebase runs everywhere                                   |
| **Correct by construction** | Dependent types catch layout, routing, and state bugs at compile time |
| **Resource safety**         | Design goal: encode resource ownership where the implementation supports it       |
| **Pure UI logic**           | View and update functions are pure; all side-effects are typed        |
| **Composable**              | Small, orthogonal primitives that compose, not inherit                |
| **Minimal runtime**         | Tiny, predictable runtime — suitable for embedded 64 KB targets       |
| **Gradual adoption**        | Can wrap native widgets or existing web components                    |

### Target Platforms

```
Web        — HTML5 Canvas / WebGL / DOM  (via Idris2 → JS)
Desktop    — SDL2 / OpenGL / Metal / Vulkan  (via Idris2 → C/RefC)
Mobile     — iOS (Metal) / Android (OpenGL ES)  (via Idris2 → C)
Embedded   — Bare-metal framebuffer, LVGL  (via Idris2 → C, minimal runtime)
TUI        — ANSI/VT100 terminal  (via Idris2 → C or JS/Node)
```

---

### Current Implementation Status

This document describes the full target architecture. The terminal, Web DOM, and
hybrid-mobile Canvas foundation is implemented; desktop, embedded, and several
advanced framework layers remain design intent. Status tags (✅ / 🚧 / 📋) are used
throughout the document to distinguish shipped behavior from plans. The executable
release checklist is [`WEB_MOBILE_COMPLETION.md`](WEB_MOBILE_COMPLETION.md).

**✅ Built and working today:**

| Area | Evidence |
| --- | --- |
| TEA core (`Core/`, `State/TEA.idr`) | Types, Widget, VTree, Runtime, Signal — real logic, no TODOs |
| VTree / Reconciler | Diffing implemented |
| TUI backend (`Backend/Terminal/*`) | 10 files, ~57 KB, zero TODOs; real POSIX/Windows terminal C shim (`c/fluxuitui.c`) |
| TUI widgets (`Widget/TUI/*`) | 8 files, ~1,065 lines |
| Web DOM backend | Typed browser events, semantic controls, responsive CSS, focus preservation, and ordered dispatch |
| Canvas/WebView backend | Rendering, responsive viewport layout, typed pointer/lifecycle events, and button/checkbox hit testing |
| Event protocol/runtime | Versioned validation, structured errors, ordered queues, and shutdown-safe command delivery |
| Router | URL parsing, path/query parameters, history commands, deep-link location events |
| Effects: Http, Keyboard | Implemented |
| Theme (`Theme/`) | Implemented (Light/Dark tokens) |
| Render IR, Animation types | Core types implemented |
| Demo apps (`examples/todo`, `examples/todo-web`) | Working — share `Todo.Update`/`View`/`Types`, swap only backend |

**📋 Designed but not started (empty directories, no code):**

- `Style/`, `A11y/`, `I18n/`
- `Widget/Input/`, `Widget/Layout/`, `Widget/Primitive/`, `Widget/Navigation/`, `Widget/Container/`
- `Backend/Mobile/`

**🚧 Partial / skeleton (some code, but with explicit TODOs or stubbed fields):**

- The older `Backend/Web/DOM.idr` PAL adapter still contains stubs; applications use
  the functional `Backend/Web/DOM/Run.idr` runner.
- `Backend/Desktop/SDL2.idr` and `Backend/Embedded/Framebuffer.idr` remain skeletons.
- `Platform/Interface.idr` has unimplemented PAL operations.
- `Layout/Types.idr` and the duplicate generic `Core/Runtime.idr` are not the layout
  and runtime used by the supported DOM/Canvas application runners.
- Canvas uses a synchronized semantic DOM overlay for native controls and text
  entry; general wrapping/scrolling remains limited. Cooperative
  `CancellableTask` effects are cancelled across pause and shutdown.

In short: **TUI remains the flagship backend**. Web DOM and Capacitor-hosted Canvas
are supported foundations with the explicit limitations in the release checklist;
desktop and embedded targets are deferred.

---

## 2. What We Steal From Whom

| Framework           | What Flux UI Borrows                                                               |
| ------------------- | ------------------------------------------------------------------------------- |
| **Elm / TEA**       | Pure Model–Msg–Update–View loop; explicit side-effects via Cmd/Sub              |
| **React**           | Virtual tree diffing; component composability; reconciler concept               |
| **Flutter**         | Widget = immutable description; RenderObject = layout+paint; three-tree model   |
| **Solid.js**        | Fine-grained reactivity; signals as first-class values; no VDOM overhead        |
| **SwiftUI**         | Opaque return types; environment/preference keys; view modifiers as composition |
| **Jetpack Compose** | Slot API; CompositionLocal; remember/side-effect scoping                        |
| **Iced (Rust)**     | Elm in a systems language; typed widget library; backend agnosticism            |
| **LVGL**            | Embedded rendering wisdom; tile-based dirty rendering; tiny memory model        |
| **Ratatui (Rust)**  | Cell buffer double-diffing; widget vocabulary; immediate-mode TUI               |
| **Bubbletea (Go)**  | Elm-inspired TUI runtime; clean separation of Model/View/Update for terminal    |
| **CSS / Yoga**      | Flexbox layout model; style inheritance; cascade                                |
| **Dear ImGui**      | Immediate-mode debug overlays; retained-mode widgets borrow its simplicity      |

### What Flux UI Does Better (thanks to Idris2)

- **Dependent types** — the widget tree can be _proven_ structurally valid at compile time
  (e.g. a `Table n` has rows of exactly `n` cells; a `Router` exhausts all routes)
- **Linear types** — a proposed way to encode resource ownership; the supported UI API does not establish a blanket no-leak guarantee
- **Algebraic effects** — platform I/O is modelled as typed effects, not stringly-typed callbacks
- **Elaborator reflection** — compile-time CSS-like DSL, zero-cost at runtime
- **Multiple backends** — Idris2 already targets JS, C (RefC), Chez Scheme, Racket;
  Flux UI piggy-backs on all of them

---

## 3. Why Idris2

```
┌──────────────────────────────────────────────────────┐
│                    Idris2 Strengths                   │
├──────────────────────────────────────────────────────┤
│  Dependent Types     → correct-by-construction UI    │
│  Linear Types        → zero-cost resource safety     │
│  Quantitative TT     → erase proofs at runtime       │
│  Algebraic Effects   → typed side-effect tracking    │
│  Elaborator Reflect  → powerful macros / DSLs        │
│  Multiple Backends   → JS, C, Chez, Racket, …        │
│  Total Functions     → no hidden runtime panics      │
└──────────────────────────────────────────────────────┘
```

---

## 4. Layered Architecture Overview

```
╔══════════════════════════════════════════════════════════════════════╗
║                         APPLICATION LAYER                            ║
║           User-written Model / View / Update / Routes                ║
╠══════════════════════════════════════════════════════════════════════╣
║                        FLUX UI CORE FRAMEWORK                        ║
║  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐               ║
║  │  State (TEA) │  │ Widget Tree  │  │ Effect System│               ║
║  │  + Signals   │  │ (VTree/Diff) │  │ (Cmd/Sub/    │               ║
║  │  + Store     │  │              │  │  Task/Port)  │               ║
║  └──────────────┘  └──────────────┘  └──────────────┘               ║
║  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐               ║
║  │Layout Engine │  │Style Engine  │  │Animation Eng.│               ║
║  │(Flexbox +    │  │(Tokens +     │  │(Tweens +     │               ║
║  │ Constraints) │  │ Cascade)     │  │ Springs)     │               ║
║  └──────────────┘  └──────────────┘  └──────────────┘               ║
║  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐               ║
║  │  Navigation  │  │   Theming    │  │     i18n     │               ║
║  │  / Router    │  │ Design Tokens│  │ Accessibility│               ║
║  └──────────────┘  └──────────────┘  └──────────────┘               ║
╠══════════════════════════════════════════════════════════════════════╣
║               PLATFORM ABSTRACTION LAYER (PAL)                       ║
║  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐            ║
║  │ Renderer │  │  Input   │  │   I/O    │  │  Window  │            ║
║  │ Driver   │  │  Driver  │  │  Driver  │  │  Driver  │            ║
║  │ (IFace)  │  │  (IFace) │  │  (IFace) │  │  (IFace) │            ║
║  └──────────┘  └──────────┘  └──────────┘  └──────────┘            ║
╠══════════════════════════════════════════════════════════════════════╣
║                         BACKEND LAYER                                ║
║  ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌─────────────┐  ║
║  │   WEB   │ │ DESKTOP │ │ MOBILE  │ │EMBEDDED │ │     TUI     │  ║
║  │DOM/Canv │ │SDL2/GLFW│ │iOS Metal│ │Framebuf │ │ANSI/VT100   │  ║
║  │WebGL    │ │OpenGL/  │ │Android  │ │LVGL     │ │Cell buffer  │  ║
║  │(JS back)│ │Vulkan/  │ │OpenGL ES│ │(C back) │ │Double-diff  │  ║
║  │         │ │Metal    │ │(C back) │ │         │ │C or Node.js │  ║
║  └─────────┘ └─────────┘ └─────────┘ └─────────┘ └─────────────┘  ║
╚══════════════════════════════════════════════════════════════════════╝
```

### Data Flow (one frame)

```
User Event
    │
    ▼
[ Input Driver ]  ──►  Normalised Event
                              │
                              ▼
                      [ Flux UI Runtime ]
                       update msg model
                              │
                   ┌──────────┴──────────┐
                   ▼                     ▼
              New Model              Cmd / Sub
                   │                     │
                   ▼                     ▼
            view newModel         Effect Executor
                   │                     │
                   ▼                     ▼
          New Widget Tree         IO / HTTP / Timer
                   │
                   ▼
           [ Differ / Reconciler ]
                   │
                   ▼
           [ Render Driver ]
                   │
                   ▼
           Platform-specific draw calls
```

---

## 5. Module Structure

Legend: ✅ Implemented · 🚧 Partial (has TODOs / stub fields) · 📋 Not started (no files yet)

```
src/
├── Main.idr                         ← entry point (runtime bootstrap)
│
└── Flux/UI/
    │
    ├── Core/                         ✅ Implemented
    │   ├── Types.idr                ← fundamental types (Color, Size, Point, Rect …)
    │   ├── Widget.idr               ← Widget type + smart constructors + DSL
    │   ├── VTree.idr                ← virtual tree node + key-based diffing
    │   ├── Reconciler.idr           ← diff two VTrees → PatchList
    │   └── Runtime.idr              ← main loop, frame scheduler (🚧 hit-testing TODO)
    │
    ├── State/                        ✅ Implemented (TEA.idr, Signal.idr — Store/Task/Port not yet written)
    │   ├── TEA.idr                  ← Model / Msg / Update / View / Cmd / Sub
    │   ├── Signal.idr               ← fine-grained reactive signals (like Solid)
    │   ├── Store.idr                ← shared global store (like Redux)
    │   ├── Task.idr                 ← async tasks (Promise-like, but typed)
    │   └── Port.idr                 ← JS interop ports / native FFI channels
    │
    ├── Layout/                       🚧 Partial (Types.idr only; well-formedness proof TODO'd out)
    │   ├── Types.idr                ← Constraint, LayoutResult, BoxModel
    │   ├── Flex.idr                 ← Flexbox algorithm (CSS-compatible)
    │   ├── Grid.idr                 ← CSS Grid subset
    │   ├── Stack.idr                ← Z-axis stacking
    │   └── Constraint.idr           ← Flutter-style min/max constraint solver
    │
    ├── Style/                        📋 Not started (empty directory)
    │   ├── Types.idr                ← StyleProp, StyleSheet, CSSValue
    │   ├── Cascade.idr              ← specificity + inheritance rules
    │   ├── Token.idr                ← design token system (spacing, radii, …)
    │   └── DSL.idr                  ← elaborator-based zero-cost style DSL
    │
    ├── Render/                       ✅ Implemented (IR types)
    │   ├── Types.idr                ← DrawCall, Canvas2D, SceneGraph node
    │   ├── Canvas.idr               ← 2-D vector draw API (path, fill, stroke)
    │   ├── Scene.idr                ← retained 3-D scene graph (optional)
    │   ├── Font.idr                 ← font loading, shaping, metrics
    │   ├── Color.idr                ← color spaces, blending modes
    │   └── Texture.idr              ← image / texture management (linear types)
    │
    ├── Effect/                       ✅ Implemented (Http.idr, Keyboard.idr — Storage/Time/Random/Platform not yet written)
    │   ├── Types.idr                ← Effect kind enumeration
    │   ├── Http.idr                 ← typed HTTP client
    │   ├── Storage.idr              ← localStorage / file / KV store
    │   ├── Time.idr                 ← timers, debounce, throttle
    │   ├── Random.idr               ← seedable PRNG effect
    │   └── Platform.idr             ← clipboard, vibration, camera, sensors …
    │
    ├── Animation/                    ✅ Implemented (core types; easing/tween)
    │   ├── Types.idr                ← Tween, Spring, Keyframe
    │   ├── Easing.idr               ← cubic-bezier, standard easings
    │   ├── Spring.idr               ← physics-based spring animation
    │   ├── Timeline.idr             ← sequence / parallel / stagger
    │   └── Transition.idr           ← enter / exit / layout transitions
    │
    ├── Platform/                     🚧 Partial (Interface.idr, Event.idr exist; some PAL fields stubbed)
    │   ├── Interface.idr            ← PAL interfaces (records of functions)
    │   ├── Event.idr                ← unified event type (pointer, key, touch …)
    │   ├── Window.idr               ← window / viewport lifecycle
    │   ├── Clipboard.idr            ← cross-platform clipboard
    │   └── Capabilities.idr         ← type-level platform capability flags
    │
    ├── Backend/
    │   ├── Web/                     🚧 Partial (DOM renderer works; 4 TODOs — no Canvas2D/WebGL yet)
    │   │   ├── DOM.idr              ← DOM manipulation via JS FFI
    │   │   ├── Canvas2D.idr         ← HTML5 Canvas 2D context
    │   │   ├── WebGL.idr            ← WebGL 2 bindings
    │   │   └── Runtime.idr          ← requestAnimationFrame loop
    │   │
    │   ├── Desktop/                 📋 Not started (SDL2.idr is a skeleton with 6 TODOs)
    │   │   ├── SDL2.idr             ← SDL2 window + event + OpenGL context
    │   │   ├── OpenGL.idr           ← OpenGL 3.3 core draw calls
    │   │   ├── Vulkan.idr           ← Vulkan (future)
    │   │   ├── Metal.idr            ← Metal for macOS/iOS (future)
    │   │   └── Runtime.idr          ← platform event loop
    │   │
    │   ├── Mobile/                  📋 Not started (empty directory)
    │   │   ├── iOS.idr              ← UIKit / Metal bridge
    │   │   ├── Android.idr          ← JNI / OpenGL ES bridge
    │   │   └── Runtime.idr
    │   │
    │   ├── Embedded/                📋 Not started (Framebuffer.idr is a skeleton with 6 TODOs)
    │   │   ├── Framebuffer.idr      ← /dev/fb0 Linux framebuffer
    │   │   ├── LVGL.idr             ← LVGL C bindings
    │   │   └── Runtime.idr          ← bare-metal / RTOS loop
    │   │
    │   └── Terminal/                ✅ Implemented — the flagship backend (10 files, zero TODOs,
    │       │                          real POSIX/Windows C shim in c/fluxuitui.c)
    │       ├── Types.idr            ← TermColor, CellStyle, Cell, CellBuffer, BorderChars
    │       ├── ANSI.idr             ← Escape sequence generators
    │       ├── Diff.idr             ← Double-buffer cell differ
    │       ├── Input.idr            ← Raw stdin reader + ANSI escape sequence parser
    │       └── Runtime.idr          ← Full PAL assembly + main loop
    │
    ├── Widget/
    │   ├── Primitive/                📋 Not started (empty directory)
    │   │   ├── Text.idr             ← Text, RichText, Label
    │   │   ├── Image.idr            ← Image, Icon, SVG
    │   │   ├── Shape.idr            ← Rectangle, Circle, Path
    │   │   └── Canvas.idr           ← low-level draw canvas widget
    │   │
    │   ├── Input/                    📋 Not started (empty directory)
    │   │   ├── Button.idr
    │   │   ├── TextInput.idr
    │   │   ├── Checkbox.idr
    │   │   ├── Radio.idr
    │   │   ├── Slider.idr
    │   │   ├── Toggle.idr
    │   │   └── Select.idr
    │   │
    │   ├── Layout/                   📋 Not started (empty directory)
    │   │   ├── Row.idr
    │   │   ├── Column.idr
    │   │   ├── Stack.idr
    │   │   ├── Grid.idr
    │   │   ├── Spacer.idr
    │   │   └── Padding.idr
    │   │
    │   ├── Container/                📋 Not started (empty directory)
    │   │   ├── Card.idr
    │   │   ├── Modal.idr
    │   │   ├── Drawer.idr
    │   │   ├── Tooltip.idr
    │   │   └── ScrollView.idr
    │   │
    │   ├── Navigation/               📋 Not started (empty directory)
    │   │   ├── Tabs.idr
    │   │   ├── NavBar.idr
    │   │   └── Breadcrumb.idr
    │   │
    │   └── TUI/                     ✅ Implemented (8 files, ~1,065 lines — see §10)
    │       ├── Primitives.idr       ← tuiText, tuiBox, tuiHBox, tuiVBox, tuiParagraph
    │       ├── List.idr             ← Scrollable selectable list
    │       ├── Table.idr            ← Bordered data table (dependent-typed columns)
    │       ├── Progress.idr         ← Progress bar, spinner, gauge
    │       ├── Input.idr            ← Text input field with cursor
    │       └── Chart.idr            ← Sparkline, bar chart, braille dot plot
    │
    ├── Router/                       🚧 Partial (Types.idr only, no parser combinators yet)
    │   ├── Types.idr                ← Route, Params, Query (dep-typed)
    │   ├── Parser.idr               ← type-safe URL parser / printer
    │   ├── Hash.idr                 ← hash-based SPA routing
    │   └── History.idr              ← History API routing
    │
    ├── Theme/                        ✅ Implemented
    │   ├── Types.idr                ← Theme record
    │   ├── Default.idr              ← built-in light + dark themes
    │   └── Context.idr              ← environment-key theme propagation
    │
    ├── I18n/                         📋 Not started (empty directory)
    │   ├── Types.idr                ← Locale, TranslationKey, Pluralisation
    │   ├── Loader.idr               ← async bundle loading
    │   └── Context.idr
    │
    └── A11y/                         📋 Not started (empty directory)
        ├── Types.idr                ← Role, ARIALabel, LiveRegion
        ├── Tree.idr                 ← accessibility tree construction
        └── Announcer.idr            ← screen-reader announcement queue
```

---

## 6. State Management — Enhanced TEA

Flux UI uses **The Elm Architecture** as its foundation, extended with **Signals** for
fine-grained reactivity and a **Store** for globally-shared state.

### 6.1 Core TEA

```
┌─────────────────────────────────────────────┐
│                  TEA Loop                   │
│                                             │
│  ┌─────────┐  msg   ┌──────────────────┐    │
│  │  View   │ ─────► │     Update       │    │
│  │ (pure)  │        │ msg → model →    │    │
│  └────▲────┘        │ (model, Cmd msg) │    │
│       │ model       └────────┬─────────┘    │
│       │                      │ Cmd          │
│       │                      ▼              │
│       │              ┌───────────────┐      │
│       └──────────────│Effect Executor│      │
│          new model   └───────────────┘      │
└─────────────────────────────────────────────┘
```

```idris
-- State/TEA.idr (sketch)
record App (model : Type) (msg : Type) where
  constructor MkApp
  init    : (model, Cmd msg)
  update  : msg -> model -> (model, Cmd msg)
  view    : model -> Widget msg
  subscriptions : model -> Sub msg
```

### 6.2 Signals (fine-grained reactivity layer — Solid.js inspiration)

Signals sit _below_ TEA for localised, high-frequency state that does not need
to flow through the full update cycle (e.g. hover state, scroll position, input
focus). They are **pure at the type level** and never escape to global state.

```
Signal<A>  =  (read : () -> A,  write : A -> IO ())
Derived<A> =  (read : () -> A)          -- computed from other signals
Effect     =  signals observed automatically during execution
```

### 6.3 Store (global shared state)

A typed store allows multiple sub-trees to share state without prop-drilling,
similar to Redux / Vuex but fully typed.

```
Store state action  ≅  IORef state  +  (action -> state -> IO state)
```

---

## 7. Widget System

Widgets are **immutable descriptions** (Flutter-style). The runtime holds the
actual state and render objects separately.

### Widget Tree (three-tree model, like Flutter)

```
Widget Tree          Element Tree          RenderObject Tree
(immutable,    ──►   (identity,      ──►   (layout + paint,
 user-built)          stateful)             backend-specific)
```

### Widget DSL Example (planned Idris2 syntax)

```idris
myView : Model -> Widget Msg
myView model =
  column [ spacing 16, padding 24 ]
    [ text model.title
        |> fontSize 24
        |> fontWeight Bold
        |> color (theme.colors.primary)
    , row [ gap 8 ]
        [ button "Decrement" (onClick Decrement)
        , text (show model.count)
        , button "Increment" (onClick Increment)
        ]
    , when model.loading $
        spinner [ size 32 ]
    ]
```

### Widget Type (core)

```idris
data Widget : (msg : Type) -> Type where
  Leaf    : WidgetNode     msg  -> Widget msg
  Node    : WidgetNode     msg
          -> List (Widget  msg) -> Widget msg
  Keyed   : String -> Widget   msg  -> Widget msg   -- diff hint
  Lazy    : (() -> Widget  msg) -> Widget msg        -- suspend evaluation
  Portal  : Widget msg -> Widget msg                 -- render outside tree
  Map     : (a -> b) -> Widget a -> Widget b         -- functor
```

---

## 8. Layout Engine

Flux UI implements a **Flexbox-compatible** layout engine (same algorithm used in
React Native, Yoga, and Flutter) with an optional **CSS Grid** subset.

### Layout is a two-pass algorithm

```
Pass 1 — Measure
  parent sends min/max Constraints to child
  child returns its desired Size

Pass 2 — Place
  parent assigns each child a final Rect
```

### Idris2 advantage — Constraint types

```idris
-- The constraint proof is erased at runtime (0-quantified)
layout : (0 proof : ValidConstraints minW maxW minH maxH)
       -> Widget msg
       -> LayoutResult
```

---

## 9. Styling System

Flux UI uses a **design-token** based style system inspired by CSS Custom Properties,
Tailwind, and Radix UI Themes.

### Three style layers

```
1. Design Tokens   (spacing scale, type scale, color palette, radii, shadows)
2. Component Styles (default styles per widget, override via theme)
3. Inline Styles   (applied directly on a widget via view modifiers)
```

### Style DSL (elaborator-based, zero runtime cost)

```idris
myStyle : StyleSheet
myStyle = stylesheet
  [ ".card" .:
      [ backgroundColor (rgb 255 255 255)
      , borderRadius (token.radii.md)
      , padding       (token.space.4)
      , shadow        token.shadows.sm
      ]
  ]
```

---

## 10. Effect System

All side-effects are **declared**, never implicit.

| Effect                 | Description          | Platform             |
| ---------------------- | -------------------- | -------------------- |
| `Http.get`             | Typed HTTP request   | Web, Desktop, Mobile |
| `Storage.set`          | KV persistence       | All                  |
| `Time.after`           | Delay / timer        | All                  |
| `Platform.vibrate`     | Haptic feedback      | Mobile               |
| `Platform.clipboard`   | Read/write clipboard | Web, Desktop         |
| `Random.next`          | Seedable random      | All                  |
| `Port.send`            | JS interop message   | Web                  |
| `Sensor.accelerometer` | Motion data          | Mobile, Embedded     |

### Cmd / Sub (Elm-compatible)

```idris
-- A Cmd is a description of a side-effect that produces msg
data Cmd : (msg : Type) -> Type

-- A Sub is a description of an ongoing subscription
data Sub : (msg : Type) -> Type

none    : Cmd msg
batch   : List (Cmd msg) -> Cmd msg
map     : (a -> b) -> Cmd a -> Cmd b
```

---

## 11. Rendering Pipeline

```
Widget Tree
    │
    ▼  (reconciler diff)
Patch List
    │
    ▼  (layout engine)
Positioned Render Tree
    │
    ▼  (paint phase)
Draw Call List  (abstract IR)
    │   ┌────────────────────────────────────┐
    ▼   │  DrawCall IR                        │
    │   │  = FillRect Rect Color              │
    │   │  | StrokeRect Rect Stroke           │
    │   │  | DrawText String Font Point Color │
    │   │  | DrawImage Texture Rect Rect      │
    │   │  | ClipRect Rect                    │
    │   │  | Transform Matrix3x3             │
    │   │  | BeginLayer Alpha                 │
    │   │  | EndLayer                         │
    │   └────────────────────────────────────┘
    │
    ▼  (backend renderer)
Platform Draw Calls
(Canvas2D / OpenGL / Metal / Vulkan / Framebuffer)
```

### Dirty Region Tracking

Only regions that changed are repainted — critical for embedded targets with
tight CPU/memory budgets.

---

## 12. Platform Abstraction Layer (PAL)

The PAL is a **record of functions** (not a typeclass) — allowing multiple
implementations to co-exist and making mocking/testing trivial.

```idris
-- Platform/Interface.idr
record Renderer where
  constructor MkRenderer
  beginFrame  : IO ()
  endFrame    : IO ()
  drawCall    : DrawCall -> IO ()
  loadTexture : Bytes -> IO (Either String TextureHandle)
  freeTexture : (1 _ : TextureHandle) -> IO ()   -- linear: must free

record InputDriver where
  constructor MkInputDriver
  pollEvents  : IO (List Event)
  setCapture  : Bool -> IO ()

record WindowDriver where
  constructor MkWindowDriver
  getSize     : IO (Int, Int)
  setTitle    : String -> IO ()
  requestRedraw : IO ()
  onResize    : (Int -> Int -> IO ()) -> IO ()
```

---

## 13. Platform Backends

### 13.1 Web Backend (Idris2 → JavaScript) — 🚧 Partial

DOM renderer exists and works (used by `examples/todo-web`); Canvas2D/WebGL renderers
and 4 other TODOs remain open.

```
Flux UI → JS codegen → browser
  ├── DOM renderer     (div/span tree, CSS layout, no canvas overhead)
  ├── Canvas2D renderer (HTML5 Canvas, pixel-perfect custom drawing)
  └── WebGL renderer   (GPU-accelerated, for heavy graphics)
```

Approach: Start with **DOM renderer** for fastest iteration;
graduate to Canvas/WebGL for performance-sensitive apps.

### 13.2 Desktop Backend (Idris2 → C via RefC) — 📋 Not started

`SDL2.idr` exists but is a skeleton with 6 open TODOs; no window actually opens yet.

```
Flux UI → C (RefC) → SDL2 + OpenGL
  ├── SDL2 window + input
  ├── OpenGL 3.3 core draw calls
  └── FreeType font rasterisation
```

Future: Vulkan, Metal (macOS), Direct3D 11 (Windows)

### 13.3 Mobile Backend (Idris2 → C → iOS / Android) — 📋 Not started

`Backend/Mobile/` is an empty directory — nothing implemented yet.

```
iOS    : Idris2 C → UIKit host app → Metal renderer
Android: Idris2 C → JNI → OpenGL ES 3.0 renderer
```

Flux UI does _not_ wrap native widgets by default — it draws everything.
Optional native widget escape hatch for platform-specific components.

### 13.4 Embedded Backend (Idris2 → C, minimal) — 📋 Not started

`Framebuffer.idr` exists but is a skeleton with 6 open TODOs.

### 13.5 TUI Backend (Idris2 → C or Node.js) — ✅ Implemented, flagship backend

```
Flux UI → C (RefC) or JS (Node) → ANSI terminal
  ├── CellBuffer double-buffering
  │     front: last rendered frame
  │     back:  current frame being drawn
  ├── Differ: compare front/back → only emit changed cells
  ├── ANSI/VT100 escape-sequence generator
  ├── Raw-mode stdin reader + escape sequence parser
  ├── Mouse tracking (SGR xterm protocol 1006)
  └── SIGWINCH / resize detection
```

#### TUI Rendering Pipeline

```
Widget Tree
    │
    ▼  (TUI layout engine — integer cell coordinates)
Positioned Cell Regions
    │
    ▼  (paint: widgets write chars+colors into back CellBuffer)
CellBuffer (back)
    │
    ▼  (differ: compare back ↔ front)
Changed Cells List
    │
    ▼  (ANSI emitter: moveCursor + SGR + char per changed cell)
stdout (single buffered write per frame)
```

#### TUI Module Structure

```
Flux/UI/Backend/Terminal/
  Types.idr        ← TermColor, CellStyle, Cell, CellBuffer, BorderChars
  ANSI.idr         ← Escape sequence generators (pure String functions)
  Diff.idr         ← Double-buffer cell differ
  Input.idr        ← Raw stdin reader + ANSI escape sequence parser
  Runtime.idr      ← Full PAL assembly + main loop

Flux/UI/Widget/TUI/
  Primitives.idr   ← tuiText, tuiBox, tuiHBox, tuiVBox, tuiParagraph
  List.idr         ← Scrollable selectable list
  Table.idr        ← Bordered data table (dependent-typed columns)
  Progress.idr     ← Progress bar, spinner, gauge
  Input.idr        ← Text input field with cursor
  Chart.idr        ← Sparkline, bar chart, braille dot plot
```

#### TUI-specific widget vocabulary

| Widget                  | Description                                      |
| ----------------------- | ------------------------------------------------ |
| `tuiText`               | Single-line styled text at a fixed cell position |
| `tuiParagraph`          | Word-wrapped multi-line text                     |
| `tuiBox`                | Bordered container with optional title           |
| `tuiHBox` / `tuiVBox`   | Horizontal / vertical layout containers          |
| `tuiList`               | Scrollable selectable list (TEA-stateless)       |
| `tuiTable`              | Bordered data table                              |
| `tuiProgress`           | `████████░░░░░░░░  62%` progress bar             |
| `tuiSpinner`            | Animated spinner (`⠋⠙⠹⠸…`) with optional label   |
| `tuiGauge`              | Labelled numeric gauge                           |
| `tuiSparkline`          | Inline `▁▂▄▅▇` sparkline from data series        |
| `tuiBarChart`           | Vertical bar chart                               |
| `tuiDotPlot`            | Braille (2×4) high-res scatter / line plot       |
| `tuiInput`              | Text input field with cursor, password mode      |
| `tuiOverlay`            | Z-stack for modals / popups                      |
| `tuiHRule` / `tuiVRule` | Horizontal / vertical rule lines                 |

#### TUI colour model

```
TermColor
  = Default                    -- terminal default fg/bg
  | Color16  n                 -- ANSI 16-color palette
  | Color256 n                 -- xterm 256-color palette
  | ColorRGB r g b             -- 24-bit truecolor
```

Flux UI automatically degrades the colour model if the terminal does not
support truecolor (detected via `$COLORTERM` env var).

#### TUI ↔ TEA integration

The TUI backend plugs in to the same `App model msg` record as every
other backend. No special TUI-specific runtime is needed:

```idris
main : IO ()
main = do
  plat <- terminalPlatform
  run myApp plat
```

All TUI widget state (list selection, input cursor, spinner tick) lives
in the application **Model** — no hidden mutable state outside TEA.
This is the key insight borrowed from Bubbletea.

```
Target: ARM Cortex-M4+, 64 KB RAM, 256 KB flash
  ├── Framebuffer renderer (16/32-bit colour)
  ├── LVGL optional C bridge
  └── No heap allocator required in hot path (linear types ensure this)
```

---

## 14. Animation System

Animations are **values in time**, not imperative mutations.

```
Tween<A>  : start A → end A → Duration → Easing → (Time → A)
Spring<A> : stiffness → damping → (target A) → (Time → A)
Timeline  : parallel | sequence | stagger of animations
```

### Transition types

- `Fade` — opacity 0→1 / 1→0
- `Slide` — translate from edge
- `Scale` — grow/shrink from center
- `Layout` — animate layout changes (like AutoLayout / Framer Motion)
- `Shared Element` — hero transitions between screens

---

## 15. Navigation & Routing

Type-safe routing where **every route is a constructor**, parameters are typed,
and missing routes are a compile error.

```idris
-- Router/Types.idr
data Route : Type where
  Home     : Route
  UserPage : (id : Nat) -> Route
  Settings : (tab : SettingsTab) -> Route
  NotFound : Route

-- The router is exhaustive — non-exhaustive match = compile error
routeToUrl : Route -> String
urlToRoute : String -> Maybe Route  -- parser combinator, total
```

Navigation stack is modelled as a `List Route` or a `Zipper Route`.

---

## 16. Theming & Design Tokens

```idris
record Theme where
  constructor MkTheme
  colors     : ColorTokens
  typography : TypographyTokens
  spacing    : SpacingScale       -- 4px base grid
  radii      : RadiiTokens
  shadows    : ShadowTokens
  motion     : MotionTokens

-- Passed implicitly through the widget tree via environment keys
-- (like React Context / SwiftUI Environment)
```

Built-in themes: **Light**, **Dark**, **High Contrast**.
Custom themes composable from base.

---

## 17. Internationalisation (i18n)

```idris
record I18nConfig where
  locale     : Locale               -- "en-GB", "ar-EG" …
  translations : Map TransKey String
  direction  : TextDirection        -- LTR | RTL
  pluralRule : Nat -> PluralForm
```

Translations loaded as typed bundles; missing keys are compile-time errors
when bundles are bundled at build time (optional strict mode).

---

## 18. Accessibility

Every widget automatically generates an **accessibility tree** node.
Developers can annotate with ARIA-compatible roles and labels.

```idris
button "Submit"
  |> role Button
  |> ariaLabel "Submit the form"
  |> ariaDisabled model.submitting
```

Screen-reader announcements routed through `A11y.Announcer` — a queue
that the platform backend reads and passes to OS accessibility APIs.

---

## 19. Developer Tooling

| Tool                | Description                                                            |
| ------------------- | ---------------------------------------------------------------------- |
| **flux-ui-devtools**   | Browser/desktop overlay: widget inspector, state timeline, performance |
| **flux-ui-hot-reload** | File watcher → recompile → hot-swap widget tree                        |
| **flux-ui-test**       | Widget testing utilities (headless renderer, event simulation)         |
| **flux-ui-bench**      | Frame-time profiler, layout hit counter                                |
| **flux-ui-gen**        | Scaffolding: `flux-ui-gen component MyButton`                             |
| **flux-ui-i18n-check** | Validates all translation keys are present in all bundles              |

---

## 20. Build System & ipkg

```
flux-ui.ipkg          — library package
flux-ui-web.ipkg      — web backend (depends: flux-ui)
flux-ui-desktop.ipkg  — desktop backend (depends: flux-ui)
flux-ui-mobile.ipkg   — mobile backend (depends: flux-ui)
flux-ui-embedded.ipkg — embedded backend (depends: flux-ui, no GC)
```

Idris2 backends used:

- `--cg javascript` → Web
- `--cg refc` → Desktop, Mobile, Embedded (C with reference counting)
- `--cg chez` → Desktop (development / scripting)

---

## 21. Phased Roadmap

> Checkboxes below are reconciled against actual source state (see
> [Current Implementation Status](#current-implementation-status)), not just intent.
> **Note:** actual progress didn't follow this phase order — the TUI backend
> (not originally its own phase) is now the most complete backend, ahead of
> Desktop/Mobile/Embedded from Phases 3/6/7.

### Phase 0 — Foundation

- [x] Create repository structure
- [x] Define all core types (`Color`, `Size`, `Rect`, `Widget`, `Cmd`, `Sub`) — `Core/Types.idr`, `State/TEA.idr`
- [x] Implement TEA runtime loop (pure, no platform) — `State/TEA.idr`, `Core/Runtime.idr` (hit-testing still TODO)
- [x] Write VTree differ / reconciler — `Core/VTree.idr`
- [x] Design PAL interfaces — `Platform/Interface.idr` (some fields still stubbed)

### Phase 1 — Web MVP

- [x] JS backend: DOM renderer — works, powers `examples/todo-web` (4 TODOs remain)
- [ ] Basic widgets: `text`, `button`, `column`, `row`, `image` — available via the core `Widget` DSL; dedicated `Widget/Primitive/*` modules not yet split out (empty dir)
- [ ] Input events: click, input, keydown — partial (Keyboard effect exists; full DOM event coverage unverified)
- [x] HTTP effect — `Effect/Http.idr`
- [ ] Basic routing (hash-based) — `Router/Types.idr` only; `Hash.idr`/`Parser.idr` not written
- [x] Counter + Todo demo apps — `examples/todo` (TUI) and `examples/todo-web` (Web) both working

### Phase 2 — Web + Styling

- [ ] Style engine: tokens, cascade, inline — `Style/` is an empty directory
- [ ] Flexbox layout engine (Web) — `Layout/Types.idr` only, no `Flex.idr` yet
- [x] Dark/light theming — `Theme/` implemented
- [ ] Canvas2D renderer option — not started
- [ ] Animation: tweens, fade/slide transitions — tween/easing *types* exist (`Animation/Types.idr`), transition wiring not confirmed

### Phase 3 — Desktop Backend

- [ ] SDL2 + OpenGL renderer (C backend) — `SDL2.idr` is a skeleton, 6 open TODOs, no window opens yet
- [ ] Font rasterisation (FreeType)
- [ ] Keyboard / mouse / gamepad input
- [ ] File I/O effect
- [ ] Desktop demo: notepad app

### Phase 4 — State & Reactivity

- [x] Signals system — `State/Signal.idr` implemented
- [ ] Store (global state) — `State/Store.idr` not written
- [ ] Derived signals / memoisation
- [ ] Performance: dirty-flag propagation

### Phase 5 — Layout Engine (full)

- [ ] CSS Grid — not started
- [ ] Constraint-based layout — `Layout/Types.idr` defines constraints; solver not implemented
- [ ] Stack / Z-order
- [ ] Responsive breakpoints

### Phase 6 — Mobile Backend

- [ ] iOS Metal renderer — `Backend/Mobile/` is an empty directory
- [ ] Android OpenGL ES renderer
- [ ] Touch input, gestures
- [ ] Platform effects: camera, sensors, haptics

### Phase 7 — Embedded Backend

- [ ] Framebuffer renderer — `Framebuffer.idr` is a skeleton, 6 open TODOs
- [ ] LVGL bridge
- [ ] No-alloc hot path
- [ ] Minimal demo on Raspberry Pi Pico

### Phase 8 — Advanced Features

- [ ] Spring animations + shared-element transitions
- [ ] Accessibility tree + screen reader — `A11y/` is an empty directory
- [ ] i18n + RTL layout — `I18n/` is an empty directory
- [ ] WebGL / Vulkan / Metal advanced renderers
- [ ] Developer tooling suite

### Phase 9 — TUI Backend *(not in original plan — happened anyway)*

- [x] Terminal PAL assembly + main loop — `Backend/Terminal/Runtime.idr`
- [x] ANSI/VT100 escape sequence generation — `Backend/Terminal/ANSI.idr`
- [x] Double-buffer cell differ — `Backend/Terminal/Diff.idr`
- [x] Raw stdin + escape sequence input parsing — `Backend/Terminal/Input.idr`
- [x] Native terminal control shim — `c/fluxuitui.c` (POSIX + Windows)
- [x] TUI widget vocabulary — `Widget/TUI/*` (list, table, progress, input, chart, primitives)
- [x] TUI demo app — `examples/todo` running end-to-end

---

## 22. Key Type Signatures (Preview)

```idris
-----------------------------------------------------------------
-- A type-safe Widget functor (like virtual DOM node)
-----------------------------------------------------------------
data Widget : (msg : Type) -> Type

Functor Widget where
  map f (Leaf n)     = Leaf (mapNode f n)
  map f (Node n cs)  = Node (mapNode f n) (map (map f) cs)
  map f (Map g w)    = Map (f . g) w

-----------------------------------------------------------------
-- Effect-typed update function
-----------------------------------------------------------------
record App model msg where
  init         : (model, Cmd msg)
  update       : msg -> model -> (model, Cmd msg)
  view         : model -> Widget msg
  subscriptions: model -> Sub msg

-----------------------------------------------------------------
-- Linear texture handle — compiler enforces free()
-----------------------------------------------------------------
data TextureHandle : Type   -- abstract

loadTexture : Bytes -> IO (Either String TextureHandle)
freeTexture : (1 h : TextureHandle) -> IO ()   -- must consume

-----------------------------------------------------------------
-- Dependent-typed route parser — exhaustive by construction
-----------------------------------------------------------------
data Route : Type where
  Home     : Route
  User     : Nat -> Route
  Settings : Route

parseRoute : (s : String) -> Dec (r : Route ** routeToUrl r = s)

-----------------------------------------------------------------
-- Layout constraints carry proof of validity
-----------------------------------------------------------------
record Constraints where
  minW : Double; maxW : Double
  minH : Double; maxH : Double
  0 wOk : minW <= maxW
  0 hOk : minH <= maxH

measure : Constraints -> Widget msg -> Size
```

---

_This document is the single source of truth for Flux UI architecture decisions.
Update it as the framework evolves._
