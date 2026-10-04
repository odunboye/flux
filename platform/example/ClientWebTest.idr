module ClientWebTest

import ClientChecks
import Iris.Client.Web
import Data.IORef

%default covering

%foreign "javascript:lambda: _w => globalThis.__rpcTestBase || ''"
prim_base : PrimIO String

%foreign "javascript:lambda: _w => globalThis.__rpcTestPooled ? 1 : 0"
prim_pooled : PrimIO Int

%foreign "javascript:lambda: (ok,_w) => { globalThis.__rpcTestResult=ok; if(typeof process!=='undefined')process.exitCode=ok===1?0:1; }"
prim_done : Int -> PrimIO ()

main : IO ()
main = do
  base <- primIO prim_base
  pooled <- primIO prim_pooled
  let client = webClient base (MkFetchOptions 10000 65536)
  runChecks client (pooled == 1) $ \ok =>
    if pooled == 1 then primIO (prim_done (if ok then 1 else 0)) else do
      -- Check both the Iris command shape and the actual abort delivery.
      failures <- newIORef (if ok then the Nat 0 else 1)
      case createTodo client (MkCreateTodoRequest "slow-test") id of
        CancellableTask action => do
          cancel <- action $ \result => do
            check failures "Iris cancellation propagates as a typed transport error"
              (case result of Left (TransportFailure Cancelled) => True; _ => False)
            n <- readIORef failures
            primIO (prim_done (if n == 0 then 1 else 0))
          cancel
        _ => primIO (prim_done 0)
