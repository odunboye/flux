||| Iris Todo — Browser/DOM entry point
||| IDENTICAL logic to examples/todo/src/Main.idr.
||| Only the last line differs: runWeb instead of runTUI.
module Main

import Iris.App
import Iris.State.TEA
import Iris.Platform.Event
import Iris.Widget.TUI.List
import Iris.Widget.TUI.Input
import Iris.Backend.Web.DOM.Run

import Todo.Types
import Todo.Update
import Todo.View

-- ─── Seed data ─────────────────────────────────────────────────────────────

seedTasks : List Task
seedTasks =
  [ MkTask 0 "Build the Iris framework"       True
  , MkTask 1 "Add TUI backend"                True
  , MkTask 2 "Write example projects"         False
  , MkTask 3 "Implement layout engine"        False
  , MkTask 4 "Add Web backend (DOM renderer)" False
  , MkTask 5 "Mobile backend (iOS + Android)" False
  ]

-- ─── Initial model ─────────────────────────────────────────────────────────

initModel : Model
initModel = MkModel
  { tasks      = seedTasks
  , nextId     = 6
  , selection  = initListState
  , textInput  = initInput
  , screen     = TaskListScreen
  , spinTick   = 0
  , statusMsg  = "[arrows] navigate  [space] toggle  [a] add  [d] delete"
  , history    = [0.0, 0.1, 0.2, 0.2, 0.3, 0.33, 0.33]
  }

-- ─── Keyboard handler ──────────────────────────────────────────────────────

handleKey : Model -> KeyEvent -> Maybe Msg
handleKey m ke =
  case m.screen of
    TaskListScreen => case ke.key of
      "ArrowUp"   => Just NavUp
      "ArrowDown" => Just NavDown
      " "         => Just ToggleSelected
      "a"         => Just GoToAdd
      "d"         => Just DeleteSelected
      "q"         => Just Quit
      _           => Nothing
    AddScreen => case ke.key of
      "Enter"     => Just Confirm
      "Escape"    => Just Cancel
      "Backspace" => Just TypeBack
      "Delete"    => Just TypeDel
      "ArrowLeft" => Just CursorLeft
      "ArrowRight"=> Just CursorRight
      "Home"      => Just CursorHome
      "End"       => Just CursorEnd
      _           => case ke.char of
                       Just c  => Just (TypeChar c)
                       Nothing => Nothing

-- ─── App (identical to terminal version) ───────────────────────────────────

todoWebApp : IrisApp Model Msg
todoWebApp = MkApp (initModel, none) update view (\m, e => case e of KeyboardEvent ke => handleKey m ke; _ => Nothing) (Just Tick)

-- ─── Entry point — the ONLY line that differs from the terminal version ─────

main : IO ()
main = runWeb todoWebApp
