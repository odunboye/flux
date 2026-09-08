||| A source of cryptographically-strong random bytes, for anything that
||| needs to be genuinely unguessable (currently just
||| `Flux.Middleware.Session`'s session IDs).
|||
||| Idris2's own `System.Random` is not suitable for this: traced to its
||| primitive (`%foreign "scheme:blodwen-random"` on the Chez backend,
||| `Math.random()` on the JS one), it's a plain, non-cryptographic PRNG
||| - not seeded from OS entropy per call, and predictable in principle
||| once its internal state is known. Nothing in this project's
||| dependency tree exposes a CSPRNG-labeled API directly, but reading
||| `/dev/urandom` does the job without needing one: `System.Posix.File`
||| (already transitively available via `Flux.Core.HTTP`, already used
||| the same way by `Flux.Middleware.Static` for regular files) wraps a
||| plain, unrestricted `open()`/`read()` with no restriction to regular
||| files and no Darwin-specific gap (unlike some of this dependency
||| stack's other POSIX bindings - see e.g.
||| `Flux.Core.HTTP.shutdownOn`'s platform note) - a character device
||| like `/dev/urandom` works identically to a regular file here, on
||| both Linux and macOS.
module Flux.Middleware.Internal.Random

import Flux.Core.HTTP
import System.Posix.File

%default covering

||| Reads `n` bytes of real OS entropy from `/dev/urandom`. Genuinely
||| fails (as `Errno`) if the device can't be opened or read - by
||| design: falling back to a weaker source on failure would silently
||| defeat the entire point of this module, so this doesn't have one.
export
randomBytes : (n : Bits32) -> Async Poll [Errno] ByteString
randomBytes n = do
  fd <- openFile "/dev/urandom" O_RDONLY 0
  bs <- System.Posix.File.read fd ByteString n
  close' fd
  pure bs

hexDigit : Bits8 -> Char
hexDigit b =
  let n = cast {to = Int} b
   in if n < 10 then cast (48 + n) else cast (87 + n)

export
toHex : ByteString -> String
toHex bs = pack (concatMap (\b => [hexDigit (b `div` 16), hexDigit (b `mod` 16)]) (unpack bs))

||| A fresh, unguessable, hex-encoded random token with `nbytes` bytes of
||| entropy (e.g. 16 for 128 bits - `Flux.Middleware.Session`'s default).
export
randomToken : (nbytes : Bits32) -> Async Poll [Errno] String
randomToken nbytes = toHex <$> randomBytes nbytes
