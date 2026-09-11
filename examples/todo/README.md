# Iris Todo Manager

A terminal-based task manager built entirely with the **Iris framework**.
It demonstrates every layer of the Iris TUI stack in a real application.

---

## What it looks like

```
╭────────────────────────────────────────────────────────────────────────────╮
│  Iris Todo Manager                                                          │
╰────────────────────────────────────────────────────────────────────────────╯

 ╭─ Tasks (6) ───────────────────────────╮   Progress
 │ ▶  [x] Build the Iris framework       │   ██████████░░░░░░░░░░  33%
 │    [x] Add TUI backend                │
 │    [ ] Write example projects         │   Done: 2 / 6
 │    [ ] Implement layout engine        │
 │    [ ] Add Web backend                │   ⠋  computing…
 │    [ ] Mobile backend                 │
 ╰───────────────────────────────────────╯   History: ▁▂▂▃▃▃▃

 [arrows] navigate  [space] toggle  [a] add  [d] delete  [q] quit
```

---

## Architecture

This example is a textbook Elm Architecture (TEA) application:

```
┌──────────────────────────────────────────────────────────────────────┐
│                           App Model                                  │
│   tasks : List Task     — raw task data                              │
│   selection : ListState — which task is highlighted + scroll offset  │
│   textInput : InputState— text being typed on the Add screen         │
│   screen : Screen       — which screen is currently showing          │
│   history : List Double — completion ratios over time (sparkline)    │
└──────────────────────────────────────────────────────────────────────┘
         │                             │
         │ view                        │ subscriptions
         ▼                             ▼
 Widget Msg tree              Sub Msg (keyboard events)
         │                             │
         ▼                             │
  TUI Renderer                         │
  (cell buffer)              ──────────┘
                                       │ Msg
                                       ▼
                              update : Msg -> Model
                                        -> (Model, Cmd Msg)
```

### Module layout

```
src/
├── Main.idr          — seed data, App wiring, entry point
└── Todo/
    ├── Types.idr     — Task, Screen, Model, Msg   (no IO)
    ├── Update.idr    — pure update function        (no IO)
    └── View.idr      — pure view function          (no IO)
```

**Zero IO in Types, Update, or View** — all platform interaction is
handled by the Iris runtime and expressed as typed `Cmd`/`Sub` values.

---

## Iris features demonstrated

| Feature | Where |
|---|---|
| TEA `App` record | `Main.idr` — `todoApp` |
| Keyboard `Sub` | `Update.idr` — `subscriptions` |
| `onKeyDown` / `matchKey` | `Update.idr` — `listKeyHandler`, `addKeyHandler` |
| `tuiList` widget | `View.idr` — `taskListWidget` |
| `tuiProgress` widget | `View.idr` — progress bar |
| `tuiSpinner` widget | `View.idr` — animated spinner |
| `tuiSparkline` widget | `View.idr` — completion history chart |
| `tuiInput` widget | `View.idr` — add-task text field |
| Multiple screens | `View.idr` — `case m.screen` dispatch |
| Pure record updates | `Update.idr` — `{ field $= f }` syntax |
| `ListState` navigation | `Update.idr` — `listUp`/`listDown` |
| `InputState` editing | `Update.idr` — `insertChar`, `deleteBack`, etc. |

---

## Controls

### Task-list screen

| Key | Action |
|---|---|
| `↑` / `↓` | Navigate tasks |
| `Space` | Toggle task completion |
| `a` | Switch to add-task screen |
| `d` | Delete the selected task |
| `q` | Quit |

### Add-task screen

| Key | Action |
|---|---|
| Any printable key | Type into task name |
| `Backspace` | Delete character before cursor |
| `←` / `→` | Move cursor |
| `Home` / `End` | Jump to start / end |
| `Enter` | Confirm and add the task |
| `Esc` | Cancel, return to task list |

---

## Build & run

```bash
# From this directory:
make run

# Or step by step:
make          # installs iris, then builds iris-todo
./build/exec/iris-todo
```

### Prerequisites

- [Idris2](https://github.com/idris-lang/Idris2) ≥ 0.7
- `make`

The `Makefile` will automatically install the iris library before
building the example.

---

## Extending the example

Some ideas to try:

1. **Due dates** — add a `dueDate : Maybe String` field to `Task`
   and display it in the list widget
2. **Priority levels** — add `priority : Priority` (High/Med/Low)
   and colour tasks accordingly using `withFg (Color16 n)`
3. **Filter screen** — add a `FilterScreen` to `Screen` showing
   only incomplete tasks
4. **Persistence** — add a `Storage.save` command in the `update`
   function to write tasks to a JSON file via `Iris.Effect.Storage`
5. **Help overlay** — render a `tuiOverlay` modal with keybindings
   when the user presses `?`
