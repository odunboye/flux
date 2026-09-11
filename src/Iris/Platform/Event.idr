||| Iris.Platform.Event
||| Unified cross-platform event type.
||| All backends normalise their native events into this type before
||| handing them to the Iris runtime.
module Iris.Platform.Event

import Iris.Core.Types

-- ─── Keyboard ──────────────────────────────────────────────────────────────

public export
record ModifierKeys where
  constructor MkModifiers
  shift : Bool
  ctrl  : Bool
  alt   : Bool
  meta  : Bool   -- Cmd on macOS, Win key on Windows

public export
data KeyAction = KeyDown | KeyUp | KeyRepeat

public export
record KeyEvent where
  constructor MkKeyEvent
  action    : KeyAction
  key       : String       -- logical key name, e.g. "Enter", "a", "ArrowUp"
  code      : String       -- physical key code, e.g. "KeyA"
  modifiers : ModifierKeys
  char      : Maybe Char   -- printable character if any

-- ─── Pointer (mouse / touch / stylus) ─────────────────────────────────────

public export
data PointerButton = PrimaryBtn | SecondaryBtn | MiddleBtn | BackBtn | ForwardBtn

public export
data PointerAction
  = PointerDown
  | PointerUp
  | PointerMove
  | PointerEnter
  | PointerLeave
  | PointerCancel

public export
data PointerKind = Mouse | Touch | Pen

public export
record PointerEvent where
  constructor MkPointerEvent
  action    : PointerAction
  kind      : PointerKind
  id        : Int              -- pointer id (multitouch)
  position  : Point            -- logical pixels, relative to window
  delta     : Point            -- movement delta
  button    : Maybe PointerButton
  pressure  : Double           -- 0.0 – 1.0
  modifiers : ModifierKeys

-- ─── Scroll ────────────────────────────────────────────────────────────────

public export
record ScrollEvent where
  constructor MkScrollEvent
  position : Point    -- pointer position when scroll occurred
  deltaX   : Double
  deltaY   : Double
  deltaZ   : Double

-- ─── Window ────────────────────────────────────────────────────────────────

public export
data Orientation = Portrait | Landscape

public export
data WindowEvent
  = WindowResized Size
  | WindowFocusGained
  | WindowFocusLost
  | WindowCloseRequested
  | WindowFullscreenChanged Bool
  | WindowOrientationChanged Orientation

-- ─── Application lifecycle / text composition ──────────────────────────────

public export
data LifecycleEvent
  = PageVisible
  | PageHidden
  | AppPaused
  | AppResumed
  | BackRequested
  | LocationChanged String -- path, query, and fragment

public export
data CompositionAction
  = CompositionStart
  | CompositionUpdate
  | CompositionEnd
  | CompositionCancel

public export
record CompositionEvent where
  constructor MkCompositionEvent
  action : CompositionAction
  text   : String

-- ─── Unified event ─────────────────────────────────────────────────────────

public export
data Event
  = KeyboardEvent   KeyEvent
  | PointerEvt      PointerEvent
  | ScrollEvt       ScrollEvent
  | WindowEvt       WindowEvent
  | LifecycleEvt    LifecycleEvent
  | CompositionEvt  CompositionEvent
  | TextInput       String       -- committed text input
  | Tick            Double       -- timestamp in milliseconds
  | Custom          String       -- escape hatch for platform-specific events
