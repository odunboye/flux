module HotDemo

import Iris.App
import Iris.State.TEA
import Iris.Widget
import Iris.Platform.Event
import Iris.Backend.Web.DOM.Run
import Data.String

%default covering

record Model where
  constructor MkModel
  count : Nat
  draft : String
  held : Bool
  ticks : Nat

data Msg = Increment | Draft String | Hold | Work | Done | Pulse

%foreign "javascript:lambda: _w => {window.__hotStarts=(window.__hotStarts||0)+1;}"
prim_started : PrimIO ()

%foreign "javascript:lambda: (send, _w) => {window.__hotCallbacks=window.__hotCallbacks||[];window.__hotCallbacks.push(()=>send(0));}"
prim_work : IO () -> PrimIO ()

%foreign "javascript:lambda: _w => {window.__hotCancelled=(window.__hotCancelled||0)+1;}"
prim_cancel : PrimIO ()

update : Nat -> Msg -> Model -> (Model, Cmd Msg)
update step Increment m = ({ count := m.count + step } m, none)
update _ (Draft value) m = ({ draft := value } m, none)
update _ Hold m = ({ held := not m.held } m, none)
update _ Work m = (m, CancellableTask (\send => do
  primIO (prim_work (send Done))
  pure (primIO prim_cancel)))
update _ Done m = ({ count := m.count + 100 } m, none)
update _ Pulse m = ({ ticks := S m.ticks } m, none)

save : Model -> Maybe String
save m = if m.held then Nothing else Just (show m.count ++ "\n" ++ show m.ticks ++ "\n" ++ m.draft)

restore : String -> Maybe Model
restore payload = case lines payload of
  [count, ticks, draft] => Just (MkModel (cast count) draft False (cast ticks))
  -- Empty drafts may be omitted by lines; accept the initial empty field too.
  [count, ticks] => Just (MkModel (cast count) "" False (cast ticks))
  _ => Nothing

public export
runDemo : String -> Nat -> String -> IO ()
runDemo heading step version =
  let application : UIApp Model Msg = MkApp (MkModel 0 "" False 0, Task (primIO prim_started >> pure Pulse))
        (update step)
        (\m => WVStack defaultStyle [text heading, text ("Count " ++ show m.count),
           text ("Ticks " ++ show m.ticks), WInput (styled [sTitle "Draft"]) m.draft Draft,
           button "Increment" Increment, button (if m.held then "Release" else "Hold") Hold,
           button "Start effect" Work])
        (\_, _ => Nothing) (Just Pulse)
  in if step == 5 then runWeb application else
       runWebHot (MkHotState version save (if step == 4 then const Nothing else restore)) application
