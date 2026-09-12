||| Todo.Update
||| Pure state-transition function: Msg -> Model -> (Model, Cmd Msg).
||| No IO here — all side-effects are returned as Cmd values.
module Todo.Update

import Iris.State.TEA
import Iris.Effect.Keyboard
import Iris.Platform.Event
import Iris.Widget.TUI.List
import Iris.Widget.TUI.Input
import Todo.Types

-- ─── Helpers ────────────────────────────────────────────────────────────────

||| Count completed tasks.
doneCount : List Task -> Nat
doneCount []        = 0
doneCount (t :: ts) = (if t.done then 1 else 0) + doneCount ts

||| Completion ratio as a Double in [0.0, 1.0].
completionRatio : List Task -> Double
completionRatio [] = 0.0
completionRatio ts =
  cast (doneCount ts) / cast (length ts)

||| Map over the task at index n.
mapTaskAt : Nat -> (Task -> Task) -> List Task -> List Task
mapTaskAt _     _ []        = []
mapTaskAt Z     f (t :: ts) = f t :: ts
mapTaskAt (S n) f (t :: ts) = t :: mapTaskAt n f ts

||| Delete the task at index n.
deleteAt : Nat -> List Task -> List Task
deleteAt _     []        = []
deleteAt Z     (_ :: ts) = ts
deleteAt (S n) (t :: ts) = t :: deleteAt n ts

||| Status message shown while on the task-list screen.
listStatus : List Task -> String
listStatus ts =
  let dc = doneCount ts
      tc = length ts
  in show dc ++ "/" ++ show tc ++ " done   "
  ++ "[arrows] navigate  [space] toggle  [a] add  [d] delete  [q] quit"

-- ─── Keyboard → Msg (used by subscriptions) ─────────────────────────────────

||| Translate a KeyEvent to a Msg on the task-list screen.
listKeyHandler : Model -> KeyEvent -> Msg
listKeyHandler _ ke =
  case ke.key of
    "ArrowUp"   => NavUp
    "ArrowDown" => NavDown
    " "         => ToggleSelected
    "a"         => GoToAdd
    "d"         => DeleteSelected
    "q"         => Quit
    _           => NoOp

||| Translate a KeyEvent to a Msg on the add screen.
addKeyHandler : KeyEvent -> Msg
addKeyHandler ke =
  case ke.key of
    "Enter"     => Confirm
    "Escape"    => Cancel
    "Backspace" => TypeBack
    "Delete"    => TypeDel
    "ArrowLeft" => CursorLeft
    "ArrowRight"=> CursorRight
    "Home"      => CursorHome
    "End"       => CursorEnd
    _           => case ke.char of
                     Just c  => TypeChar c
                     Nothing => NoOp

-- ─── Subscriptions ──────────────────────────────────────────────────────────

||| Active subscriptions depend on which screen is showing.
public export
subscriptions : Model -> Sub Msg
subscriptions m =
  case m.screen of
    TaskListScreen => onKeyDown (listKeyHandler m)
    AddScreen      => onKeyDown addKeyHandler

-- ─── Update ─────────────────────────────────────────────────────────────────

||| Pure state transition.
public export
update : Msg -> Model -> (Model, Cmd Msg)

-- Navigation on task-list screen
update NavUp m =
  let cnt = length m.tasks
  in ({ selection $= listUp cnt } m, none)

update NavDown m =
  let cnt = length m.tasks
  in ({ selection $= listDown cnt } m, none)

-- Toggle the selected task's done flag
update ToggleSelected m =
  let idx     = m.selection.selectedIndex
      updated = mapTaskAt idx (\t => { done $= not } t) m.tasks
      ratio   = completionRatio updated
  in ( { tasks    := updated
       , history $= (ratio ::)
       , statusMsg := listStatus updated
       } m
     , none )

-- Delete the selected task, move selection up if needed
update DeleteSelected m =
  let idx     = m.selection.selectedIndex
      updated = deleteAt idx m.tasks
      cnt     = length updated
      newSel  = if idx > 0 && idx >= cnt
                  then MkListState
                         (m.selection.selectedIndex `minus` 1)
                         m.selection.scrollOffset
                  else m.selection
  in ( { tasks     := updated
       , selection := newSel
       , statusMsg := listStatus updated
       } m
     , none )

-- Switch to the Add screen
update GoToAdd m =
  ( { screen    := AddScreen
    , textInput := clearInput m.textInput
    , statusMsg := "[enter] confirm  [esc] cancel"
    } m
  , none )

-- Return to the task list
update GoToList m =
  ( { screen    := TaskListScreen
    , statusMsg := listStatus m.tasks
    } m
  , none )

update Cancel m = update GoToList m

-- Confirm: on AddScreen add the task; elsewhere no-op
update Confirm m =
  case m.screen of
    AddScreen =>
      let title = m.textInput.value
      in if length title == 0
           then ( { statusMsg := "Task name cannot be empty!" } m, none )
           else
             let newTask = MkTask m.nextId title False
                 updated = m.tasks ++ [newTask]
             in ( { tasks     := updated
                  , nextId   $= (+ 1)
                  , screen    := TaskListScreen
                  , textInput := clearInput m.textInput
                  , statusMsg := listStatus updated
                  } m
                , none )
    _ => (m, none)

-- Text input on Add screen
update (TypeString s) m =
  ({ textInput $= \ti => MkInputState s (length s) False 0 } m, none)

update (TypeChar c) m =
  ({ textInput $= insertChar c } m, none)

update TypeBack m =
  ({ textInput $= deleteBack } m, none)

update TypeDel m =
  ({ textInput $= deleteForward } m, none)

update CursorLeft m =
  ({ textInput $= cursorLeft } m, none)

update CursorRight m =
  ({ textInput $= cursorRight } m, none)

update CursorHome m =
  ({ textInput $= cursorToHome } m, none)

update CursorEnd m =
  ({ textInput $= cursorToEnd } m, none)

-- Animation tick: advance the spinner
update Tick m = ({ spinTick $= (+ 1) } m, none)

-- Quit signals the TUI runtime to exit cleanly
update Quit m = (m, quit)
update NoOp m = (m, none)
