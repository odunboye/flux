||| Iris.Core.VTree
||| Virtual tree node + key-based differ.
module Iris.Core.VTree

import Data.Maybe
import Iris.Core.Types

-- ─── VNode ─────────────────────────────────────────────────────────────────

public export
data VNode : Type where
  VElement : (tag      : String)
           -> (key     : Maybe String)
           -> (props   : List (String, String))
           -> (children: List VNode)
           -> VNode
  VText : String -> VNode

-- ─── Patch ─────────────────────────────────────────────────────────────────

public export
data Patch : Type where
  Insert     : (path : List Nat) -> (index : Nat) -> VNode -> Patch
  Remove     : (path : List Nat) -> (index : Nat) -> Patch
  Replace    : (path : List Nat) -> VNode -> Patch
  UpdateProps: (path : List Nat)
             -> (added : List (String, String))
             -> (removed : List String) -> Patch
  Move       : (path : List Nat) -> (from : Nat) -> (to : Nat) -> Patch

-- ─── Prop helpers ──────────────────────────────────────────────────────────

lookupProp : String -> List (String, String) -> Maybe String
lookupProp _ []              = Nothing
lookupProp k ((k2,v) :: rest) =
  if k == k2 then Just v else lookupProp k rest

diffProps : List Nat
          -> List (String, String)
          -> List (String, String)
          -> List Patch
diffProps path old new =
  let added   = filter (\(k,v) => lookupProp k old /= Just v) new
      removed = map (\(k,_) => k) (filter (\(k,v2) => isNothing (lookupProp k new)) old)
  in if null added && null removed
       then []
       else [UpdateProps path added removed]

-- ─── Differ (mutual recursion) ─────────────────────────────────────────────

mutual
  ||| Compute the minimal patch list to transform `old` into `new`.
  public export
  diff : List Nat -> VNode -> VNode -> List Patch
  diff path (VText a) (VText b) =
    if a == b then [] else [Replace path (VText b)]
  diff path (VText _) new =
    [Replace path new]
  diff path _ (VText t) =
    [Replace path (VText t)]
  diff path (VElement ot _ ops ocs) (VElement nt nk nps ncs) =
    if ot /= nt
      then [Replace path (VElement nt nk nps ncs)]
      else diffProps path ops nps ++ diffChildren path 0 ocs ncs

  diffChildren : List Nat -> Nat -> List VNode -> List VNode -> List Patch
  diffChildren _    _ []       []       = []
  diffChildren path i []       (n::ns)  = Insert path i n :: diffChildren path (i+1) [] ns
  diffChildren path i (_::os)  []       = Remove path i   :: diffChildren path i     os  []
  diffChildren path i (o::os)  (n::ns)  =
    diff (path ++ [i]) o n ++ diffChildren path (i+1) os ns
