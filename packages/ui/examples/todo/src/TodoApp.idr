||| TodoApp
||| The single shared Flux UI application definition.
|||
||| This module contains everything that is platform-agnostic:
|||   • seed data          • initial model
|||   • keyboard handler   • the UIApp value itself
|||
||| Platform entry points (one per target) just do:
|||
|||   main = runTUI    todoApp   -- terminal
|||   main = runWeb    todoApp   -- browser
|||   main = runMobile  todoApp  -- Canvas/WebView
module TodoApp

import Flux.UI.App
import Flux.UI.State.TEA
import Flux.UI.Platform.Event
import Flux.UI.Widget.TUI.List
import Flux.UI.Widget.TUI.Input

import Todo.Types
import Todo.Update
import Todo.View

-- ─── Seed data ───────────────────────────────────────────────────────────────

public export
seedTasks : List Task
seedTasks =
  [ MkTask 0 "Build the Flux UI framework"       True
  , MkTask 1 "Add TUI backend"                True
  , MkTask 2 "Write example projects"         False
  , MkTask 3 "Implement layout engine"        False
  , MkTask 4 "Add Web backend (DOM renderer)" False
  , MkTask 5 "Mobile backend (iOS + Android)" False
  ]

-- ─── Initial model ───────────────────────────────────────────────────────────

public export
initModel : Model
initModel = MkModel
  { tasks      = seedTasks
  , nextId     = 6
  , selection  = initListState
  , textInput  = initInput
  , screen     = TaskListScreen
  , spinTick   = 0
  , statusMsg  = "[arrows] navigate  [space] toggle  [a] add  [d] delete  [q] quit"
  , history    = [0.0, 0.1, 0.2, 0.2, 0.3, 0.33, 0.33]
  }

-- ─── Keyboard handler ────────────────────────────────────────────────────────
-- Uses browser KeyboardEvent.key naming — works identically on every backend.

public export
handleKey : Model -> KeyEvent -> Maybe Msg
handleKey m ke =
  case m.screen of
    TaskListScreen => case ke.key of
      "ArrowUp"    => Just NavUp
      "ArrowDown"  => Just NavDown
      " "          => Just ToggleSelected
      "a"          => Just GoToAdd
      "d"          => Just DeleteSelected
      "q"          => Just Quit
      _            => Nothing
    AddScreen => case ke.key of
      "Enter"      => Just Confirm
      "Escape"     => Just Cancel
      "Backspace"  => Just TypeBack
      "Delete"     => Just TypeDel
      "ArrowLeft"  => Just CursorLeft
      "ArrowRight" => Just CursorRight
      "Home"       => Just CursorHome
      "End"        => Just CursorEnd
      _            => case ke.char of
                        Just c  => Just (TypeChar c)
                        Nothing => Nothing

-- ─── The application — shared across all platforms ───────────────────────────

||| The Flux UI Todo application.
||| Pass this to the backend entry point of your choice:
|||
|||   runTUI     todoApp   ← terminal
|||   runWeb     todoApp   ← browser
|||   runDesktop todoApp   ← desktop window  (future)
|||   runMobile  todoApp   ← iOS / Android   (future)
public export
todoApp : UIApp Model Msg
todoApp = MkApp (initModel, none) update view (\m, e => case e of KeyboardEvent ke => handleKey m ke; _ => Nothing) (Just Tick)
