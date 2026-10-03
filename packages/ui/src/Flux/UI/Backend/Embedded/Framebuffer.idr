||| Legacy or experimental API; not a supported application runner.
||| Start with Flux.UI, Flux.UI.App.UIApp and a specialized runner.
||| See packages/ui/API_STABILITY.md and CAPABILITIES.md.
||| Flux.UI.Backend.Embedded.Framebuffer
||| Bare-metal Linux framebuffer (/dev/fb0) backend.
||| Designed for ARM Cortex-M4+ and Raspberry Pi.
||| Key constraints: no heap allocator in hot path, minimal stack usage.
module Flux.UI.Backend.Embedded.Framebuffer

import Flux.UI.Core.Types
import Flux.UI.Render.Types
import Flux.UI.Platform.Interface
import Flux.UI.Platform.Event

-- ─── Framebuffer config ────────────────────────────────────────────────────

public export
record FBConfig where
  constructor MkFBConfig
  device      : String   -- e.g. "/dev/fb0"
  width       : Int
  height      : Int
  bitsPerPixel: Int      -- 16 or 32

-- ─── Low-level helpers (must be defined before the record) ─────────────────

fbFillRect : FBConfig -> Rect -> Color -> IO ()
fbFillRect _ _ _ = pure ()  -- TODO: blit pixels via FFI

fbBeginFrame : FBConfig -> IO ()
fbBeginFrame _ = pure ()   -- TODO: memset framebuffer to background color

fbEndFrame : FBConfig -> IO ()
fbEndFrame _ = pure ()     -- TODO: flush dirty regions to /dev/fb0

fbDrawCall : FBConfig -> DrawCall -> IO ()
fbDrawCall cfg (FillRect r c)        = fbFillRect cfg r c
fbDrawCall cfg (FillRoundRect r _ c) = fbFillRect cfg r c  -- simplified
fbDrawCall _   (DrawText _ _ _ _)    = pure ()             -- TODO: bitmap font
fbDrawCall _   (PushClip _)          = pure ()             -- TODO: software clip
fbDrawCall _    PopClip              = pure ()
fbDrawCall _    _                    = pure ()             -- unsupported on embedded

-- ─── Framebuffer renderer ──────────────────────────────────────────────────

||| Construct the framebuffer renderer.
public export
fbRenderer : FBConfig -> Renderer
fbRenderer cfg = MkRenderer
  { beginFrame    = fbBeginFrame cfg
  , endFrame      = fbEndFrame cfg
  , submitCall    = fbDrawCall cfg
  , loadTexture   = \_, _, _ => pure (Left "Use pre-decoded pixel arrays on embedded")
  , freeTexture   = \(MkTextureHandle _) => pure ()
  , surfaceSize   = pure (MkSize (cast cfg.width) (cast cfg.height))
  , pixelRatio    = pure 1.0
  }

-- ─── Embedded input driver ─────────────────────────────────────────────────

||| Reads from /dev/input/event* (evdev) or a custom GPIO driver.
public export
fbInput : InputDriver
fbInput = MkInputDriver
  { pollEvents      = pure []   -- TODO: evdev poll
  , setCapture      = \_ => pure ()
  , setSoftKeyboard = \_ => pure ()
  }

-- ─── Embedded window driver ────────────────────────────────────────────────

public export
fbWindow : FBConfig -> WindowDriver
fbWindow cfg = MkWindowDriver
  { getSize       = pure (MkSize (cast cfg.width) (cast cfg.height))
  , setTitle      = \_ => pure ()   -- no-op
  , requestRedraw = pure ()
  , onResize      = \_ => pure ()   -- no-op
  , onClose       = \_ => pure ()
  }

-- ─── Full Embedded platform ────────────────────────────────────────────────

public export
embeddedPlatform : FBConfig -> Flux.UI.Platform.Interface.Platform
embeddedPlatform cfg = MkPlatform (fbRenderer cfg) fbInput (fbWindow cfg)
