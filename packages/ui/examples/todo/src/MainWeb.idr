||| Web / DOM entry point — Idris2 JavaScript backend
module MainWeb
import Flux.UI.Backend.Web.DOM.Run
import Todo.Types   -- needed so the type-checker can resolve Model / Msg
import TodoApp
main : IO ()
main = runWeb todoApp
