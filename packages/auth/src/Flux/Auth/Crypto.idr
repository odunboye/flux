module Flux.Auth.Crypto

import Flux.Platform.Endpoint

%default covering

%foreign "C:flux_auth_begin,libflux_auth"
begin : String -> String -> Int -> PrimIO AnyPtr
%foreign "C__collect_safe:flux_auth_run,libflux_auth"
run : AnyPtr -> PrimIO Int
%foreign "C:flux_auth_hash,libflux_auth"
resultHash : AnyPtr -> PrimIO String
%foreign "C:flux_auth_end,libflux_auth"
end : AnyPtr -> PrimIO ()
%foreign "C:flux_auth_token,libflux_auth"
token : PrimIO AnyPtr
%foreign "C:flux_auth_digest,libflux_auth"
digest : String -> PrimIO AnyPtr
%foreign "C:flux_auth_string,libflux_auth"
getString : AnyPtr -> PrimIO String
%foreign "C:flux_auth_free_string,libflux_auth"
freeString : AnyPtr -> PrimIO ()

copyString : AnyPtr -> IO (Maybe String)
copyString p = if prim__nullAnyPtr p /= 0 then pure Nothing else do
  value <- primIO (getString p)
  primIO (freeString p)
  pure (Just value)

export
newToken : IO (Maybe String)
newToken = primIO token >>= copyString

export
tokenDigest : String -> IO (Maybe String)
tokenDigest value = primIO (digest value) >>= copyString

export
validToken : String -> Bool
validToken value = length (unpack value) == 43 &&
  all (\c => (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
             (c >= '0' && c <= '9') || c == '-' || c == '_') (unpack value)

export
validPassword : String -> Bool
validPassword value = let cs = unpack value in length cs >= 15 && length cs <= 256 && not (elem '\0' cs)

export
boundedPassword : String -> Bool
boundedPassword value = let cs = unpack value in not (null cs) && length cs <= 256 && not (elem '\0' cs)

-- Native strings are copied before scheduling; no managed pointers cross the
-- collect-safe call. Runtime bracket joins cancelled blocking jobs before wiping
-- native buffers and releasing the admission slot. Nothing is abandoned.
work : String -> String -> Int -> AppProg (Int, String)
work password encoded verify = bracket
  (liftIO (primIO (begin password encoded verify)))
  (\p => liftIO (primIO (end p)))
  (\p => if prim__nullAnyPtr p /= 0 then throw (MkAppError 429 "Authentication temporarily unavailable") else do
    Right code <- blocking (primIO (run p))
      | Left _ => throw (MkAppError 503 "Authentication temporarily unavailable")
    if code < 0 then throw (MkAppError 500 "Authentication unavailable") else do
      hash <- liftIO (primIO (resultHash p))
      pure (code, hash))

export
hashPassword : String -> AppProg String
hashPassword password =
  if validPassword password then snd <$> work password "" 0
    else throw (MkAppError 400 "Invalid password format")

export
verifyPassword : String -> String -> AppProg Bool
verifyPassword password encoded =
  if not (boundedPassword password) then throw (MkAppError 400 "Invalid password format")
    else if length (unpack encoded) >= 128 || elem '\0' (unpack encoded)
      then throw (MkAppError 500 "Authentication unavailable")
      else (== 1) . fst <$> work password encoded 1

||| Startup-only dummy verifier, random on each service start. Never a real account.
export
newDummy : IO (Maybe String)
newDummy = do
  Just password <- newToken | Nothing => pure Nothing
  p <- primIO (begin password "" 0)
  if prim__nullAnyPtr p /= 0 then pure Nothing else do
    code <- primIO (run p)
    hash <- primIO (resultHash p)
    primIO (end p)
    pure (if code == 1 then Just hash else Nothing)
