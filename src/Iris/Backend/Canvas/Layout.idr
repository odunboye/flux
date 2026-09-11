||| Pure Canvas interaction layout and hit testing.
module Iris.Backend.Canvas.Layout

import Iris.Widget
import Iris.Backend.Terminal.WidgetRender

public export
data HitTarget msg
  = ActivateTarget Nat WRect msg
  | InputTarget Nat WRect String (String -> msg)

public export
targetId : HitTarget msg -> Nat
targetId (ActivateTarget value _ _) = value
targetId (InputTarget value _ _ _) = value

public export
targetRect : HitTarget msg -> WRect
targetRect (ActivateTarget _ rect _) = rect
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
  collect next (WButton _ _ message) rect =
    (S next, [ActivateTarget next rect message])
  collect next (WCheckbox _ _ message) rect =
    (S next, [ActivateTarget next rect message])
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
