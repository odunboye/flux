module MainWeb

import TodoUI
import Flux.Platform.Client.Web
import Flux.UI.Backend.Web.DOM.Run

main : IO ()
main = runWeb (todoApp (webClient "" (MkFetchOptions 10000 65536)))
