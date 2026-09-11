module Main

import System
import Iris.Widget
import Iris.Backend.Canvas.Layout

widget : Widget Nat
widget = vstack
  [ button "first" 10
  , checkbox False 20
  , input "value" length
  ]

messageAt : Nat -> Nat -> Maybe Nat
messageAt col row =
  case hitAt col row (layoutTargets widget 40 10) of
    Just (ActivateTarget _ _ message) => Just message
    Just (InputTarget _ _ value handler) => Just (handler value)
    Nothing => Nothing

assert : String -> Bool -> IO ()
assert _ True = pure ()
assert label False = do
  putStrLn ("Canvas layout test failed: " ++ label)
  exitFailure

main : IO ()
main = do
  assert "button hit" (messageAt 1 0 == Just 10)
  assert "checkbox hit" (messageAt 1 1 == Just 20)
  assert "input hit" (messageAt 1 2 == Just 5)
  assert "right boundary is exclusive" (messageAt 40 0 == Nothing)
  assert "outside vertical bounds" (messageAt 1 9 == Nothing)
  putStrLn "Canvas layout tests passed"
