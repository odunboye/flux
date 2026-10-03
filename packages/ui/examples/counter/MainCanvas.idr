module MainCanvas

import Counter
import Flux.UI.Backend.Canvas.Run

main : IO ()
main = runCanvas counter
