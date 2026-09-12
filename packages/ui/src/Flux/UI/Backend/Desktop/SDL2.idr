||| Flux.UI.Backend.Desktop.SDL2
||| SDL2 + OpenGL desktop renderer backend.
||| Compiles under the `--cg refc` (C) backend.
module Flux.UI.Backend.Desktop.SDL2

import Flux.UI.Core.Types
import Flux.UI.Render.Types
import Flux.UI.Platform.Interface
import Flux.UI.Platform.Event

-- ─── SDL2 FFI stubs ────────────────────────────────────────────────────────
-- Real implementation uses %foreign "C:SDL_Init,libSDL2" etc.

||| Opaque SDL window pointer.
data SDLWindow : Type where [external]

||| Opaque OpenGL context pointer.
data GLContext : Type where [external]

-- ─── Low-level helpers ─────────────────────────────────────────────────────

sdl2BeginFrame : IO ()
sdl2BeginFrame = pure ()   -- TODO: glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT)

sdl2EndFrame : IO ()
sdl2EndFrame = pure ()     -- TODO: SDL_GL_SwapWindow(window)

sdl2SubmitCall : DrawCall -> IO ()
sdl2SubmitCall (FillRect _ _)     = pure ()  -- TODO: render quad via OpenGL
sdl2SubmitCall (DrawText _ _ _ _) = pure ()  -- TODO: FreeType glyph atlas
sdl2SubmitCall _                  = pure ()

sdl2PollEvents : IO (List Event)
sdl2PollEvents = pure []   -- TODO: SDL_PollEvent loop → normalise to Flux UI Event

-- ─── SDL2 Renderer ─────────────────────────────────────────────────────────

||| Construct the SDL2 + OpenGL renderer.
public export
sdl2Renderer : Renderer
sdl2Renderer = MkRenderer
  { beginFrame    = sdl2BeginFrame
  , endFrame      = sdl2EndFrame
  , submitCall    = sdl2SubmitCall
  , loadTexture   = \_, _, _ => pure (Left "SDL2 texture loading not yet implemented")
  , freeTexture   = \(MkTextureHandle _) => pure ()
  , surfaceSize   = pure (MkSize 1280 720)
  , pixelRatio    = pure 1.0
  }

-- ─── SDL2 Input driver ─────────────────────────────────────────────────────

public export
sdl2Input : InputDriver
sdl2Input = MkInputDriver
  { pollEvents      = sdl2PollEvents
  , setCapture      = \_ => pure ()
  , setSoftKeyboard = \_ => pure ()
  }

-- ─── SDL2 Window driver ────────────────────────────────────────────────────

public export
sdl2Window : WindowDriver
sdl2Window = MkWindowDriver
  { getSize       = pure (MkSize 1280 720)
  , setTitle      = \_ => pure ()   -- TODO: SDL_SetWindowTitle
  , requestRedraw = pure ()
  , onResize      = \_ => pure ()
  , onClose       = \_ => pure ()
  }

-- ─── Full Desktop platform ─────────────────────────────────────────────────

||| The complete SDL2 platform bundle. Pass this to `Flux.UI.Core.Runtime.run`.
public export
desktopPlatform : Flux.UI.Platform.Interface.Platform
desktopPlatform = MkPlatform sdl2Renderer sdl2Input sdl2Window
