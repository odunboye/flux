module ClientNativeTest

import ClientChecks
import Flux.Platform.Client.Native
import System

%default covering

main : IO ()
main = do
  args <- getArgs
  case args of
    [_, base] => runChecks (nativeClient base) False $ \ok =>
      if ok then putStrLn "PASS native Flux UI client checks complete" >> exitSuccess else exitFailure
    _ => putStrLn "usage: client-native-test BASE_URL" >> exitFailure
