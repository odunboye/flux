||| Iris.Router.Types
||| Type-safe routing — every route is a data constructor, every URL
||| parse/print is total, and an unmatched route is a compile-time error.
module Iris.Router.Types

-- ─── Route interface ───────────────────────────────────────────────────────

||| Implement this interface to get a type-safe router for free.
||| @route  The sum type enumerating all application routes.
public export
interface Router (route : Type) where
  ||| Serialise a route to a URL path string.
  toUrl   : route -> String
  ||| Parse a URL path string into a route (total — unknown paths → Nothing).
  fromUrl : String -> Maybe route

-- ─── Navigation actions ────────────────────────────────────────────────────

||| Commands the router understands.
public export
data NavCmd : (route : Type) -> Type where
  ||| Push a new route onto the history stack.
  Push    : route -> NavCmd route
  ||| Replace the current history entry.
  Replace : route -> NavCmd route
  ||| Go back n steps in history.
  Back    : (n : Nat) -> NavCmd route
  ||| Go forward n steps in history.
  Forward : (n : Nat) -> NavCmd route

-- ─── Navigation state ──────────────────────────────────────────────────────

||| A non-empty history stack with a cursor.
public export
record NavState (route : Type) where
  constructor MkNavState
  back    : List route   -- reversed: head is most-recent back entry
  current : route
  forward : List route

||| Initialise navigation at a given route.
public export
initNav : route -> NavState route
initNav r = MkNavState [] r []

||| Apply a NavCmd to the navigation state.
public export
applyNav : NavCmd route -> NavState route -> NavState route
applyNav (Push r)    s = MkNavState (s.current :: s.back) r []
applyNav (Replace r) s = MkNavState s.back r s.forward
applyNav (Back Z)    s = s
applyNav (Back (S n)) s =
  case s.back of
    []      => s
    (b::bs) =>
      let s' = MkNavState bs b (s.current :: s.forward)
      in applyNav (Back n) s'
applyNav (Forward Z)    s = s
applyNav (Forward (S n)) s =
  case s.forward of
    []      => s
    (f::fs) =>
      let s' = MkNavState (s.current :: s.back) f fs
      in applyNav (Forward n) s'
