module Network.Timeout

import public Network.Deadline

||| Compatibility helper: network syscalls honor the deadline, and the action
||| is always joined before returning. Arbitrary user IO must return by itself;
||| it is never forked or abandoned. Resource-producing callers should use
||| withDeadline, which retains a late result so it can be cleaned up.
export
withTimeout : Nat -> IO a -> IO (Maybe a)
withTimeout millis action = do
  (expired, result) <- withDeadline millis action
  pure (if expired then Nothing else Just result)
