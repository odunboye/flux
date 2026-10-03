module TerminalLifecycle

import Flux.UI
import Flux.UI.Backend.Terminal.Run
import Data.IORef

%default covering

data Msg = Stop

update : Msg -> () -> ((), Cmd Msg)
update Stop model = (model, quit)

main : IO ()
main = do
  cancellations <- newIORef 0
  let effect : Cmd Msg = CancellableTask (\_ => pure (modifyIORef cancellations S))
  let application : UIApp () Msg = MkApp ((), Batch [effect, MapCmd id effect])
        update (\_ => text "Lifecycle ready")
        (\_, event => case event of
          KeyboardEvent ke => if ke.key == "q" then Just Stop else Nothing
          _ => Nothing) Nothing
  runTUI application
  count <- readIORef cancellations
  putStrLn ("Lifecycle cancellations: " ++ show count)
