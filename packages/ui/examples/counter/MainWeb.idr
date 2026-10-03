module MainWeb

import Counter
import Flux.UI.Backend.Web.DOM.Run

main : IO ()
main = runWeb counter
