module CanvasLifecycle

import Flux.UI
import Flux.UI.Backend.Canvas.Run

%default covering

data Msg = Increment | Stop

%foreign "javascript:lambda: (send,_w) => {window.__lifecycleStarts=(window.__lifecycleStarts||0)+1;window.__lifecycleLate=()=>send(0);}"
prim_start : IO () -> PrimIO ()

%foreign "javascript:lambda: _w => {window.__lifecycleCancels=(window.__lifecycleCancels||0)+1;window.__lifecycleLate();}"
prim_cancel : PrimIO ()

update : Msg -> Nat -> (Nat, Cmd Msg)
update Increment count = (S count, none)
update Stop count = (count, quit)

main : IO ()
main = runCanvas $ MkApp
  (0, CancellableTask (\send => do
    primIO (prim_start (send Increment))
    pure (primIO prim_cancel)))
  update
  (\count => vstack [text ("Count: " ++ show count),
    WButton (sPad 1 defaultStyle) "Quit" Stop])
  (\_, event => case event of
    KeyboardEvent ke => if ke.key == "q" then Just Stop else Nothing
    _ => Nothing) Nothing
