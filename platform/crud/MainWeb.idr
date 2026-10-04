module MainWeb

import TodoUI
import Iris.Client.Web
import Iris.Backend.Web.DOM.Run

main : IO ()
main = runWeb (todoApp (webClient "" (MkFetchOptions 10000 65536)))
