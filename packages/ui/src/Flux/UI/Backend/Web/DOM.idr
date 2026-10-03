||| Legacy or experimental API; not a supported application runner.
||| Start with Flux.UI, Flux.UI.App.UIApp and a specialized runner.
||| See packages/ui/API_STABILITY.md and CAPABILITIES.md.
||| Flux.UI.Backend.Web.DOM
||| DOM renderer backend — Idris2 JS codegen target.
||| Translates Flux UI DrawCall IR into DOM mutations and CSS.
module Flux.UI.Backend.Web.DOM

import Flux.UI.Core.Types
import Flux.UI.Render.Types
import Flux.UI.Platform.Interface
import Flux.UI.Platform.Event

-- ─── Low-level helpers ─────────────────────────────────────────────────────

submitDrawCall : DrawCall -> IO ()
submitDrawCall (FillRect _ _)     = pure ()   -- TODO: DOM div / CSS
submitDrawCall (DrawText _ _ _ _) = pure ()   -- TODO: DOM span
submitDrawCall (PushClip _)       = pure ()   -- TODO: overflow:hidden
submitDrawCall  PopClip           = pure ()
submitDrawCall  _                 = pure ()

domPollEvents : IO (List Event)
domPollEvents = pure []   -- TODO: drain event queue populated by JS listeners

-- ─── DOM Renderer ──────────────────────────────────────────────────────────

||| Construct the DOM renderer PAL record.
public export
domRenderer : Renderer
domRenderer = MkRenderer
  { beginFrame    = pure ()
  , endFrame      = pure ()
  , submitCall    = submitDrawCall
  , loadTexture   = \_, _, _ => pure (Left "DOM texture loading not yet implemented")
  , freeTexture   = \(MkTextureHandle _) => pure ()
  , surfaceSize   = pure (MkSize 800 600)
  , pixelRatio    = pure 1.0
  }

-- ─── Input driver ──────────────────────────────────────────────────────────

public export
domInput : InputDriver
domInput = MkInputDriver
  { pollEvents      = domPollEvents
  , setCapture      = \_ => pure ()
  , setSoftKeyboard = \_ => pure ()
  }

-- ─── Window driver ─────────────────────────────────────────────────────────

public export
domWindow : WindowDriver
domWindow = MkWindowDriver
  { getSize       = pure (MkSize 800 600)
  , setTitle      = \_ => pure ()
  , requestRedraw = pure ()
  , onResize      = \_ => pure ()
  , onClose       = \_ => pure ()
  }

-- ─── Full Web platform ─────────────────────────────────────────────────────

||| The complete Web platform bundle. Pass this to `Flux.UI.Core.Runtime.run`.
public export
webPlatform : Flux.UI.Platform.Interface.Platform
webPlatform = MkPlatform domRenderer domInput domWindow
