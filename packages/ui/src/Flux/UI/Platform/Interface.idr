||| Flux.UI.Platform.Interface
||| The Platform Abstraction Layer (PAL).
||| Each backend supplies concrete implementations of these records.
||| Using records (not interfaces/typeclasses) means multiple implementations
||| can coexist, and testing is trivial — just swap the record.
module Flux.UI.Platform.Interface

import Flux.UI.Core.Types
import Flux.UI.Render.Types
import Flux.UI.Platform.Event

-- ─── Renderer ──────────────────────────────────────────────────────────────

||| Everything the Flux UI runtime needs from a rendering backend.
public export
record Renderer where
  constructor MkRenderer
  ||| Called at the start of every frame.
  beginFrame    : IO ()
  ||| Called at the end of every frame (flush / swap buffers).
  endFrame      : IO ()
  ||| Submit one draw call.
  submitCall    : DrawCall -> IO ()
  ||| Upload image bytes → GPU texture.  Returns a linear handle.
  loadTexture   : (bytes : List Bits8) -> (w : Int) -> (h : Int)
                -> IO (Either String TextureHandle)
  ||| Free a texture.  Linear: the caller must not use the handle after this.
  freeTexture   : (1 h : TextureHandle) -> IO ()
  ||| Query the current drawable surface size in physical pixels.
  surfaceSize   : IO Size
  ||| Device pixel ratio (e.g. 2.0 on Retina displays).
  pixelRatio    : IO Double

-- ─── Input driver ──────────────────────────────────────────────────────────

||| Abstracts over DOM events / SDL2 events / touch events …
public export
record InputDriver where
  constructor MkInputDriver
  ||| Collect all pending events since last frame.
  pollEvents    : IO (List Event)
  ||| Enable/disable pointer capture (useful for drag operations).
  setCapture    : Bool -> IO ()
  ||| Show or hide the soft keyboard (mobile / embedded).
  setSoftKeyboard : Bool -> IO ()

-- ─── Window driver ─────────────────────────────────────────────────────────

public export
record WindowDriver where
  constructor MkWindowDriver
  ||| Get logical window size.
  getSize       : IO Size
  ||| Set window title (no-op on mobile / embedded).
  setTitle      : String -> IO ()
  ||| Request a repaint on the next opportunity.
  requestRedraw : IO ()
  ||| Register a resize callback.
  onResize      : (Size -> IO ()) -> IO ()
  ||| Register a close/destroy callback.
  onClose       : IO () -> IO ()

-- ─── Platform bundle ───────────────────────────────────────────────────────

||| The full set of platform services passed to the Flux UI runtime.
public export
record Platform where
  constructor MkPlatform
  renderer  : Renderer
  input     : InputDriver
  window    : WindowDriver
