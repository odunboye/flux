||| Todo.View
||| Pure view: Model -> Widget Msg
||| Uses the abstract Iris.Widget tree — renders identically on every backend.
module Todo.View

import Iris.Widget
import Iris.Widget.TUI.Input
import Iris.Widget.TUI.List
import Todo.Types

-- ─── Utilities ───────────────────────────────────────────────────────────────

doneCount : List Task -> Nat
doneCount = foldl (\n, t => n + (if t.done then 1 else 0)) 0

taskRatio : List Task -> Double
taskRatio [] = 0.0
taskRatio ts = cast (doneCount ts) / cast (length ts)

-- Defined first so it can be used in the view functions below
mapWithIndex : (Nat -> a -> b) -> List a -> List b
mapWithIndex f xs = go 0 xs
  where
    go : Nat -> List a -> List b
    go _ []        = []
    go n (x :: xs) = f n x :: go (n + 1) xs

-- ─── Task list items ─────────────────────────────────────────────────────────

taskItem : Nat -> Nat -> Task -> Widget Msg
taskItem selIdx idx t =
  let mark  = if t.done then "[x]" else "[ ]"
      label = "  " ++ mark ++ " " ++ t.title
      sty   = if idx == selIdx
                then styled [bg ICyan, fg IBlack, sFillH]
                else styled [sFillH]
  in WText sty label

-- ─── Right panel ─────────────────────────────────────────────────────────────

rightPanel : Model -> Widget Msg
rightPanel m =
  WVStack (styled [sFixedW 32, sPadH 2])
    [ WText (styled [sBold]) "Progress"
    , WProgress defaultStyle (taskRatio m.tasks)
    , WText defaultStyle
        ("Done: " ++ show (doneCount m.tasks) ++ " / " ++ show (length m.tasks))
    , WSpinner defaultStyle m.spinTick
    , WText (styled [fg IGreen]) "History:"
    , WSparkline (styled [fg IGreen, sFixedW 24]) (reverse m.history)
    ]

-- ─── Task-list screen ────────────────────────────────────────────────────────

taskListScreen : Model -> Widget Msg
taskListScreen m =
  WVStack (styled [sFixedW 80, sFixedH 24])
    [ WText (styled [bg IBlue, fg IWhite, sBold, sFixedW 80, sFixedH 3])
            "  Iris Todo"

    , WHStack (styled [sFixedW 80, sFixedH 18])
        [ WVStack (styled [ sFixedW 46, sFixedH 18
                           , sBorder ThinBorder
                           , sTitle ("Tasks (" ++ show (length m.tasks) ++ ")") ])
            (mapWithIndex (taskItem m.selection.selectedIndex) m.tasks)

        , rightPanel m
        ]

    , WText (styled [bg IBlack, fg IGray, sFixedW 80, sFixedH 1])
            ("  " ++ m.statusMsg)
    ]

-- ─── Add-task screen ─────────────────────────────────────────────────────────

addTaskScreen : Model -> Widget Msg
addTaskScreen m =
  WVStack (styled [sFixedW 80, sFixedH 24])
    [ WText (styled [bg IBlue, fg IWhite, sBold, sFixedW 80, sFixedH 3])
            "  Iris Todo  >  Add Task"

    , WText (styled [sPadH 4, sPadV 1]) "Task name:"

    , WInput (styled [sFixedW 72, sBorder ThinBorder, sPadH 4])
             (InputState.value m.textInput)
             TypeString

    , WText (styled [bg IBlack, fg IGray, sFixedW 80, sFixedH 1])
            "  [Enter] confirm   [Esc] cancel"
    ]

-- ─── Root view ───────────────────────────────────────────────────────────────

public export
view : Model -> Widget Msg
view m =
  case m.screen of
    TaskListScreen => taskListScreen m
    AddScreen      => addTaskScreen m
