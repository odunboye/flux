module Main

import System
import Iris.Widget
import Iris.Backend.Canvas.Layout
import Iris.Backend.Terminal.WidgetRender

widget : Widget Nat
widget = vstack
  [ button "first" 10
  , checkbox False 20
  , input "value" length
  ]

messageAt : Nat -> Nat -> Maybe Nat
messageAt col row =
  case hitAt col row (layoutTargets widget 40 10) of
    Just (ButtonTarget _ _ _ message) => Just message
    Just (CheckboxTarget _ _ _ message) => Just message
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
  let wrappedSize = measure (the (Widget Nat) (wrappedText "abcdefghij")) 5 10
  assert "wrapped text uses available rows" (wrappedSize.w == 5 && wrappedSize.h == 2)
  let scrollSize = measure (scrollView 0 2 widget) 20 6
  assert "scroll viewport uses available bounds" (scrollSize.w == 20 && scrollSize.h == 6)
  assert "scroll offset transforms and clips hit targets"
    (case hitAt 1 0 (layoutTargets (scrollView 0 1 widget) 20 2) of
       Just (CheckboxTarget _ _ _ 20) => True
       _ => False)
  let enlarged = minimumHitTargets 5 2 (layoutTargets (button "tap" 7) 40 10)
  assert "minimum touch width" (case hitAt 4 0 enlarged of
                                  Just (ButtonTarget _ _ _ 7) => True
                                  _ => False)
  assert "minimum touch height" (case hitAt 0 1 enlarged of
                                   Just (ButtonTarget _ _ _ 7) => True
                                   _ => False)
  let semantics = semanticOverlay 10.0 20.0 (layoutTargets widget 40 10)
  assert "semantic button" (contains "aria-label='first'" semantics)
  assert "semantic checkbox" (contains "type='checkbox'" semantics)
  assert "semantic text input" (contains "aria-label='Canvas text input'" semantics)
  assert "delegated activation" (contains "data-iris-canvas-activate='" semantics)
  assert "delegated text input" (contains "data-iris-canvas-input='" semantics)
  assert "no inline handlers" (not (contains "onclick=" semantics) &&
                               not (contains "oninput=" semantics) &&
                               not (contains "onchange=" semantics))
  let captures = capturePointer 2 20 (capturePointer 1 10 [])
  let (first, afterFirst) = releasePointer 1 captures
  let (second, afterSecond) = releasePointer 2 afterFirst
  assert "independent first pointer capture" (first == Just 10)
  assert "independent second pointer capture" (second == Just 20)
  assert "captures released" (afterSecond == [])
  putStrLn "Canvas layout tests passed"
  where
    startsWith : List Char -> List Char -> Bool
    startsWith [] _ = True
    startsWith _ [] = False
    startsWith (x :: xs) (y :: ys) = x == y && startsWith xs ys

    tails : List a -> List (List a)
    tails [] = [[]]
    tails value@(_ :: rest) = value :: tails rest

    contains : String -> String -> Bool
    contains needle haystack = any (startsWith (unpack needle)) (tails (unpack haystack))
