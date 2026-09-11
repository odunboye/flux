module Network.Deadline

import Network.Socket
import Data.Buffer

%default covering

%foreign "C:pg_deadline_push,libidris2_pg_transport"
primPush : Int -> PrimIO Int64
%foreign "C:pg_deadline_restore,libidris2_pg_transport"
primRestore : Int64 -> PrimIO ()
%foreign "C:pg_deadline_expired,libidris2_pg_transport"
primExpired : PrimIO Int
%foreign "C__collect_safe:pg_socket_connect,libidris2_pg_transport"
primConnect : Int -> AnyPtr -> Int -> PrimIO Int
%foreign "C:pg_copy_host,libidris2_pg_transport"
primCopyHost : String -> PrimIO AnyPtr
%foreign "C:pg_free_host,libidris2_pg_transport"
primFreeHost : AnyPtr -> PrimIO ()
%foreign "C__collect_safe:pg_socket_receive,libidris2_pg_transport"
primReceive : Int -> Buffer -> Int -> PrimIO Int
%foreign "C__collect_safe:pg_socket_send,libidris2_pg_transport"
primSend : Int -> Buffer -> Int -> PrimIO Int

-- __collect_safe lets other workers collect while this syscall waits.
-- Pin the managed bytevector until the native call returns.
%foreign "scheme:(lambda (buffer) (lock-object buffer))"
primLockBuffer : Buffer -> PrimIO ()
%foreign "scheme:(lambda (buffer) (unlock-object buffer))"
primUnlockBuffer : Buffer -> PrimIO ()

||| Executes on this thread and returns only after the action has stopped.
||| True reports deadline expiry. The result is retained for resource cleanup.
export
withDeadline : Nat -> IO a -> IO (Bool, a)
withDeadline milliseconds action = do
  previous <- primIO (primPush (cast (min milliseconds 2147483647)))
  result <- action
  expired <- primIO primExpired
  primIO (primRestore previous)
  pure (expired /= 0, result)

export
connectSocket : Socket -> String -> Int -> IO Int
connectSocket socket host port = do
  pointer <- primIO (primCopyHost host)
  if prim__nullAnyPtr pointer /= 0 then pure (-1) else do
    result <- primIO (primConnect socket.descriptor pointer port)
    primIO (primFreeHost pointer)
    pure result

fill : Buffer -> Int -> List Bits8 -> IO ()
fill _ _ [] = pure ()
fill buffer i (b :: bs) = setBits8 buffer i b >> fill buffer (i + 1) bs

readBytes : Buffer -> Int -> Int -> IO (List Bits8)
readBytes buffer i n = if i >= n then pure [] else do
  b <- getBits8 buffer i
  bs <- readBytes buffer (i + 1) n
  pure (b :: bs)

export
sendSocket : Socket -> List Bits8 -> IO (Either String Int)
sendSocket socket bytes = do
  let count = cast (length bytes)
  Just buffer <- newBuffer count | Nothing => pure (Left "send buffer allocation failed")
  fill buffer 0 bytes
  primIO (primLockBuffer buffer)
  n <- primIO (primSend socket.descriptor buffer count)
  primIO (primUnlockBuffer buffer)
  pure (if n < 0 then Left ("socket send failed: " ++ show n) else Right n)

export
receiveSocket : Socket -> Int -> IO (Either String (List Bits8))
receiveSocket socket size = do
  let count = min size 65536
  Just buffer <- newBuffer count | Nothing => pure (Left "receive buffer allocation failed")
  primIO (primLockBuffer buffer)
  n <- primIO (primReceive socket.descriptor buffer count)
  primIO (primUnlockBuffer buffer)
  if n < 0 then pure (Left ("socket receive failed: " ++ show n))
    else Right <$> readBytes buffer 0 n
