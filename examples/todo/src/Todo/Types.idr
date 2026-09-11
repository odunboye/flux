||| Todo.Types
||| All shared types for the Iris Todo example.
||| Model and Msg live together to avoid circular imports.
module Todo.Types

import Iris.Widget
import Iris.Widget.TUI.List
import Iris.Widget.TUI.Input

-- ─── Task ───────────────────────────────────────────────────────────────────

||| A single task in the todo list.
public export
record Task where
  constructor MkTask
  taskId    : Nat
  title     : String
  done      : Bool

-- ─── Screens ────────────────────────────────────────────────────────────────

||| Which screen is currently visible.
public export
data Screen
  = ||| Main task list screen.
    TaskListScreen
  | ||| The "add a new task" input screen.
    AddScreen

-- ─── Model ──────────────────────────────────────────────────────────────────

||| The complete application state.
public export
record Model where
  constructor MkModel
  ||| All tasks (most-recent first after add).
  tasks      : List Task
  ||| Monotonically-increasing counter for unique task IDs.
  nextId     : Nat
  ||| List-widget navigation state (selection + scroll offset).
  selection  : ListState
  ||| Text-input state for the Add screen.
  textInput  : InputState
  ||| Which screen is visible.
  screen     : Screen
  ||| Spinner animation tick (increments each frame).
  spinTick   : Nat
  ||| One-line status / help message shown at the bottom.
  statusMsg  : String
  ||| Completion history (one entry per Add action) for the sparkline.
  history    : List Double

-- ─── Messages ───────────────────────────────────────────────────────────────

||| Every user action or event that can change the Model.
public export
data Msg
  = -- ── List-screen navigation ──────────────────────────────────────────
    NavUp
  | NavDown
  | -- ── Task operations ─────────────────────────────────────────────────
    ToggleSelected
  | DeleteSelected
  | -- ── Screen transitions ──────────────────────────────────────────────
    GoToAdd
  | GoToList
  | -- ── Add-screen text input ────────────────────────────────────────────
    Confirm           -- Enter: confirm add / action
  | Cancel            -- Esc:   cancel / go back
  | TypeChar   Char   -- one character typed (TUI keyboard)
  | TypeString String  -- full value update (DOM input onChange)
  | TypeBack          -- Backspace
  | TypeDel           -- Delete key
  | CursorLeft
  | CursorRight
  | CursorHome
  | CursorEnd
  | -- ── Application ────────────────────────────────────────────────────
    Quit
  | NoOp
  | Tick   -- animation clock tick (spinner advance)
