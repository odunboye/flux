module Main

import System
import Iris.Widget
import Iris.Backend.Web.DOM.Render

startsWith : List Char -> List Char -> Bool
startsWith [] _ = True
startsWith _ [] = False
startsWith (x :: xs) (y :: ys) = x == y && startsWith xs ys

contains : String -> String -> Bool
contains needle haystack = any (startsWith (unpack needle)) (tails (unpack haystack))
  where
    tails : List a -> List (List a)
    tails [] = [[]]
    tails value@(_ :: rest) = value :: tails rest

assert : String -> Bool -> IO ()
assert _ True = pure ()
assert label False = do
  putStrLn ("DOM renderer test failed: " ++ label)
  exitFailure

main : IO ()
main = do
  let inputStyle = sTitle "Task name" defaultStyle
  let checkStyle = sTitle "Task complete" defaultStyle
  (html, _, _) <- renderPage $ vstack
    [ text "<unsafe & text>"
    , WInput inputStyle "a'b" (const 0)
    , WCheckbox checkStyle True 1
    , button "Save & close" 2
    , progress 0.5
    , spinner 1
    ]
  assert "HTML escaping" (contains "&lt;unsafe &amp; text&gt;" html)
  assert "input value escaping" (contains "value='a&#39;b'" html)
  assert "input accessible name" (contains "aria-label='Task name'" html)
  assert "checkbox accessible name" (contains "aria-label='Task complete'" html)
  assert "checked state" (contains " checked" html)
  assert "button accessible name" (contains "aria-label='Save &amp; close'" html)
  assert "delegated button event" (contains "data-iris-click='" html)
  assert "delegated input event" (contains "data-iris-input='" html)
  assert "no inline event handlers" (not (contains "onclick=" html) &&
                                      not (contains "oninput=" html) &&
                                      not (contains "onchange=" html))
  assert "progress semantics" (contains "role='progressbar'" html && contains "aria-valuenow='50'" html)
  assert "live status" (contains "role='status'" html && contains "aria-live='polite'" html)
  assert "group semantics" (contains "role='group'" html)
  assert "focus indicator CSS" (contains ":focus-visible" irisCSS)
  assert "reduced motion CSS" (contains "prefers-reduced-motion" irisCSS)
  putStrLn "DOM renderer tests passed"
