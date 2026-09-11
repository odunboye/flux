||| Mobile entry point — HTML5 Canvas + Capacitor (iOS / Android)
module MainMobile
import Iris.Backend.Canvas.Run
import Todo.Types
import TodoApp
main : IO ()
main = runMobile todoApp
