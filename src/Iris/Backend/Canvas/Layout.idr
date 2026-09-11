||| Pure Canvas interaction layout and hit testing.
module Iris.Backend.Canvas.Layout

import Iris.Widget
import Iris.Backend.Terminal.WidgetRender

public export
data HitTarget msg
  = ButtonTarget Nat WRect String msg
  | CheckboxTarget Nat WRect Bool msg
  | InputTarget Nat WRect String (String -> msg)

public export
targetId : HitTarget msg -> Nat
targetId (ButtonTarget value _ _ _) = value
targetId (CheckboxTarget value _ _ _) = value
targetId (InputTarget value _ _ _) = value

public export
PointerCaptures : Type
PointerCaptures = List (Int, Nat)

public export
capturePointer : Int -> Nat -> PointerCaptures -> PointerCaptures
capturePointer pointer target captures =
  (pointer, target) :: filter (\entry => fst entry /= pointer) captures

public export
cancelPointer : Int -> PointerCaptures -> PointerCaptures
cancelPointer pointer = filter (\entry => fst entry /= pointer)

public export
releasePointer : Int -> PointerCaptures -> (Maybe Nat, PointerCaptures)
releasePointer pointer captures = (findCapture captures, cancelPointer pointer captures)
  where
    findCapture : PointerCaptures -> Maybe Nat
    findCapture [] = Nothing
    findCapture ((candidate, target) :: rest) =
      if candidate == pointer then Just target else findCapture rest

public export
targetRect : HitTarget msg -> WRect
targetRect (ButtonTarget _ rect _ _) = rect
targetRect (CheckboxTarget _ rect _ _) = rect
targetRect (InputTarget _ rect _ _) = rect

inside : Nat -> Nat -> WRect -> Bool
inside col row rect =
  col >= rect.col && row >= rect.row &&
  col < rect.col + rect.w && row < rect.row + rect.h

||| Hit-test in reverse paint order so the visually topmost target wins.
public export
hitAt : Nat -> Nat -> List (HitTarget msg) -> Maybe (HitTarget msg)
hitAt col row targets = findHit (reverse targets)
  where
    findHit : List (HitTarget msg) -> Maybe (HitTarget msg)
    findHit [] = Nothing
    findHit (target :: rest) =
      if inside col row (targetRect target) then Just target else findHit rest

mutual
  collect : Nat -> Widget msg -> WRect -> (Nat, List (HitTarget msg))
  collect next (WButton _ label message) rect =
    (S next, [ButtonTarget next rect label message])
  collect next (WCheckbox _ checked message) rect =
    (S next, [CheckboxTarget next rect checked message])
  collect next (WInput _ value handler) rect =
    (S next, [InputTarget next rect value handler])
  collect next (WVStack style children) rect =
    let inner = innerRect style rect
        sizes = distributeV children inner.w inner.h
    in collectV next children sizes inner.col inner.row inner.w inner.h
  collect next (WHStack style children) rect =
    let inner = innerRect style rect
        sizes = distributeH children inner.w inner.h
    in collectH next children sizes inner.col inner.row inner.w inner.h
  collect next _ _ = (next, [])

  collectV : Nat -> List (Widget msg) -> List WSize -> Nat -> Nat -> Nat -> Nat
          -> (Nat, List (HitTarget msg))
  collectV next [] _ _ _ _ _ = (next, [])
  collectV next (child :: children) (size :: sizes) col row maxW maxH =
    let childW = if widgetFillH child then maxW else min size.w maxW
        childH = size.h
        (afterChild, childTargets) = collect next child (MkWRect col row childW childH)
        (afterRest, restTargets) = collectV afterChild children sizes col
          (row + childH) maxW (maxH `minus` childH)
    in (afterRest, childTargets ++ restTargets)
  collectV next (_ :: children) [] col row maxW maxH =
    collectV next children [] col row maxW maxH

  collectH : Nat -> List (Widget msg) -> List WSize -> Nat -> Nat -> Nat -> Nat
          -> (Nat, List (HitTarget msg))
  collectH next [] _ _ _ _ _ = (next, [])
  collectH next (child :: children) (size :: sizes) col row maxW maxH =
    let childW = size.w
        childH = if widgetFillV child then maxH else min size.h maxH
        (afterChild, childTargets) = collect next child (MkWRect col row childW childH)
        (afterRest, restTargets) = collectH afterChild children sizes
          (col + childW) row (maxW `minus` childW) maxH
    in (afterRest, childTargets ++ restTargets)
  collectH next (_ :: children) [] col row maxW maxH =
    collectH next children [] col row maxW maxH

||| Compute interactive rectangles with exactly the same stack distribution
||| used by the Canvas renderer.
public export
layoutTargets : Widget msg -> Nat -> Nat -> List (HitTarget msg)
layoutTargets widget cols rows = snd (collect 0 widget (MkWRect 0 0 cols rows))

escapeAttribute : String -> String
escapeAttribute value = concatMap escape (unpack value)
  where
    escape : Char -> String
    escape '&' = "&amp;"
    escape '<' = "&lt;"
    escape '>' = "&gt;"
    escape '"' = "&quot;"
    escape '\'' = "&#39;"
    escape char = pack [char]

semanticStyle : Double -> Double -> WRect -> String
semanticStyle cellW cellH rect =
  "position:absolute;left:" ++ show (cast rect.col * cellW) ++ "px;top:" ++
  show (cast rect.row * cellH) ++ "px;width:" ++ show (cast rect.w * cellW) ++
  "px;height:" ++ show (cast rect.h * cellH) ++ "px;box-sizing:border-box;"

||| Build the transparent native-control layer associated with a Canvas. It
||| supplies keyboard focus, mobile text input, and screen-reader semantics
||| while Canvas remains responsible for visual rendering.
public export
semanticOverlay : Double -> Double -> List (HitTarget msg) -> String
semanticOverlay cellW cellH = concatMap renderTarget
  where
    renderTarget : HitTarget msg -> String
    renderTarget (ButtonTarget id rect label _) =
      "<button class='iris-canvas-control' aria-label='" ++ escapeAttribute label ++
      "' style='" ++ semanticStyle cellW cellH rect ++ "' " ++
      "data-iris-canvas-activate='" ++ show id ++ "'></button>"
    renderTarget (CheckboxTarget id rect checked _) =
      "<input class='iris-canvas-control' type='checkbox' aria-label='Toggle' " ++
      (if checked then "checked " else "") ++ "style='" ++ semanticStyle cellW cellH rect ++
      "' data-iris-canvas-activate='" ++ show id ++ "'/>"
    renderTarget (InputTarget id rect value _) =
      "<input class='iris-canvas-control iris-canvas-input' type='text' " ++
      "aria-label='Canvas text input' autocomplete='off' id='iris-canvas-input-" ++
      show id ++ "' style='" ++ semanticStyle cellW cellH rect ++ "' value='" ++
      escapeAttribute value ++ "' data-iris-canvas-input='" ++ show id ++ "'/>"
