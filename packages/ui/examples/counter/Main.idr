module Main

import Counter
import Flux.UI.Backend.Terminal.Run

main : IO ()
main = runTUI counter
