||| Terminal entry point — Chez Scheme / native binary
module Main
import Iris.Backend.Terminal.Run
import Todo.Types   -- needed so the type-checker can resolve Model / Msg
import TodoApp
main : IO ()
main = runTUI todoApp
