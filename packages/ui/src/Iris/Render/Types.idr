||| Iris.Render.Types
||| Abstract rendering intermediate representation (IR).
||| Every backend translates this IR into its own draw calls.
||| Keeping the IR small keeps backends easy to port.
module Iris.Render.Types

import Iris.Core.Types

-- ─── Font ──────────────────────────────────────────────────────────────────

public export
data FontWeight = Thin | ExtraLight | Light | Regular | Medium
                | SemiBold | Bold | ExtraBold | Black

public export
record Font where
  constructor MkFont
  family  : String
  size    : Px
  weight  : FontWeight
  italic  : Bool
  lineHeight : Maybe Px

public export
defaultFont : Font
defaultFont = MkFont "system-ui" 16 Regular False Nothing

-- ─── Stroke ────────────────────────────────────────────────────────────────

public export
data LineCap  = ButtCap | RoundCap | SquareCap
public export
data LineJoin = MiterJoin | RoundJoin | BevelJoin

public export
record Stroke where
  constructor MkStroke
  color  : Color
  width  : Px
  cap    : LineCap
  join   : LineJoin
  dashes : List Px   -- empty = solid

-- ─── Shadow ────────────────────────────────────────────────────────────────

public export
record Shadow where
  constructor MkShadow
  offsetX : Px
  offsetY : Px
  blur    : Px
  spread  : Px
  color   : Color
  inset   : Bool

-- ─── Path ──────────────────────────────────────────────────────────────────

public export
data PathOp
  = MoveTo Point
  | LineTo Point
  | QuadTo Point Point        -- control, end
  | CubicTo Point Point Point -- c1, c2, end
  | ArcTo  Point Point Px     -- tangent1, tangent2, radius
  | Close

public export
Path : Type
Path = List PathOp

-- ─── Texture handle (linear type — must be freed) ──────────────────────────

||| An opaque handle to a GPU-side texture.
||| Declared as a linear type: the compiler will ensure freeTexture is called.
public export
data TextureHandle : Type where
  MkTextureHandle : Int -> TextureHandle   -- backend-specific id

-- ─── Draw Call IR ──────────────────────────────────────────────────────────

||| The abstract draw call instruction set.
||| Backends translate this to Canvas2D / OpenGL / Metal / framebuffer ops.
public export
data DrawCall
  = -- 2-D primitives
    FillRect      Rect Color
  | StrokeRect    Rect Stroke
  | FillRoundRect Rect Px Color          -- radius
  | FillCircle    Point Px Color         -- center, radius
  | FillPath      Path Color
  | StrokePath    Path Stroke
    -- Text
  | DrawText      String Font Point Color
    -- Images / textures
  | DrawTexture   TextureHandle Rect Rect  -- src rect, dst rect
    -- Clipping
  | PushClip      Rect
  | PopClip
    -- Transform
  | PushTransform (List Double)            -- 3x3 matrix row-major
  | PopTransform
    -- Compositing layers (for opacity / blend modes)
  | PushLayer     Double                   -- alpha
  | PopLayer
    -- Shadows
  | PushShadow    Shadow
  | PopShadow

-- ─── Frame ─────────────────────────────────────────────────────────────────

||| A complete list of draw calls for one rendered frame.
public export
Frame : Type
Frame = List DrawCall
