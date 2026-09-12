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

shiftRectInto : WRect -> Nat -> Nat -> WRect -> Maybe WRect
shiftRectInto viewport scrollX scrollY rect =
  let originX = viewport.col + scrollX
      originY = viewport.row + scrollY
      cutX = originX `minus` rect.col
      cutY = originY `minus` rect.row
      shiftedCol = viewport.col + (rect.col `minus` originX)
      shiftedRow = viewport.row + (rect.row `minus` originY)
      visibleW = min (rect.w `minus` cutX) ((viewport.col + viewport.w) `minus` shiftedCol)
      visibleH = min (rect.h `minus` cutY) ((viewport.row + viewport.h) `minus` shiftedRow)
  in if visibleW == 0 || visibleH == 0 then Nothing
     else Just (MkWRect shiftedCol shiftedRow visibleW visibleH)

shiftTargetInto : WRect -> Nat -> Nat -> HitTarget msg -> Maybe (HitTarget msg)
shiftTargetInto viewport x y (ButtonTarget id rect label message) =
  map (\visible => ButtonTarget id visible label message) (shiftRectInto viewport x y rect)
shiftTargetInto viewport x y (CheckboxTarget id rect checked message) =
  map (\visible => CheckboxTarget id visible checked message) (shiftRectInto viewport x y rect)
shiftTargetInto viewport x y (InputTarget id rect value handler) =
  map (\visible => InputTarget id visible value handler) (shiftRectInto viewport x y rect)

keepJust : List (Maybe a) -> List a
keepJust [] = []
keepJust (Nothing :: rest) = keepJust rest
keepJust (Just value :: rest) = value :: keepJust rest

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
  collect next (WScroll style scrollX scrollY child) rect =
    let viewport = innerRect style rect
        contentSize = measure child 10000 10000
        (afterChild, targets) = collect next child
          (MkWRect viewport.col viewport.row contentSize.w contentSize.h)
    in (afterChild, keepJust (map (shiftTargetInto viewport scrollX scrollY) targets))
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

expandRect : Nat -> Nat -> WRect -> WRect
expandRect minimumW minimumH rect =
  MkWRect rect.col rect.row (max minimumW rect.w) (max minimumH rect.h)

||| Enforce minimum logical hit dimensions without changing visual layout.
public export
minimumHitTargets : Nat -> Nat -> List (HitTarget msg) -> List (HitTarget msg)
minimumHitTargets minimumW minimumH = map expand
  where
    expand : HitTarget msg -> HitTarget msg
    expand (ButtonTarget id rect label message) =
      ButtonTarget id (expandRect minimumW minimumH rect) label message
    expand (CheckboxTarget id rect checked message) =
      CheckboxTarget id (expandRect minimumW minimumH rect) checked message
    expand (InputTarget id rect value handler) =
      InputTarget id (expandRect minimumW minimumH rect) value handler

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
      "' data-iris-style='" ++ semanticStyle cellW cellH rect ++ "' " ++
      "data-iris-canvas-activate='" ++ show id ++ "'></button>"
    renderTarget (CheckboxTarget id rect checked _) =
      "<input class='iris-canvas-control' type='checkbox' aria-label='Toggle' " ++
      (if checked then "checked " else "") ++ "data-iris-style='" ++ semanticStyle cellW cellH rect ++
      "' data-iris-canvas-activate='" ++ show id ++ "'/>"
    renderTarget (InputTarget id rect value _) =
      "<input class='iris-canvas-control iris-canvas-input' type='text' " ++
      "aria-label='Canvas text input' autocomplete='off' id='iris-canvas-input-" ++
      show id ++ "' data-iris-style='" ++ semanticStyle cellW cellH rect ++ "' value='" ++
      escapeAttribute value ++ "' data-iris-canvas-input='" ++ show id ++ "'/>"
