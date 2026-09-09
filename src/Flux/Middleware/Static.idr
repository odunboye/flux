||| Serves files from a directory on disk. Mount it under a route with a
||| splat segment so nested paths work, e.g.:
||| `get "/static/*path" (staticHandler "public" defaultMimeFor) router`.
module Flux.Middleware.Static

import public Flux.Core.HTTP
import public Flux.Core.Middleware
import Data.List1
import Data.String

%default covering

||| Maps a file extension (no leading dot) to a MIME type, falling back to
||| "application/octet-stream" for anything unrecognized.
export
defaultMimeFor : String -> String
defaultMimeFor ext = case toLower ext of
  "html" => "text/html"
  "htm"  => "text/html"
  "css"  => "text/css"
  "js"   => "application/javascript"
  "json" => "application/json"
  "txt"  => "text/plain"
  "png"  => "image/png"
  "jpg"  => "image/jpeg"
  "jpeg" => "image/jpeg"
  "gif"  => "image/gif"
  "svg"  => "image/svg+xml"
  "pdf"  => "application/pdf"
  "ico"  => "image/x-icon"
  "wasm" => "application/wasm"
  _      => "application/octet-stream"

-- The substring after the last '.', or "" if there isn't one.
export
extensionOf : String -> String
extensionOf path = case go (reverse (unpack path)) of
  Nothing    => ""
  Just chars => pack (reverse chars)
  where
    -- Nothing until a '.' is actually found; Just the characters seen
    -- since then otherwise. Distinguishes "no dot at all" from "found
    -- the extension", so e.g. "README" doesn't get treated as an
    -- extension-less name that returns itself.
    go : List Char -> Maybe (List Char)
    go [] = Nothing
    go ('.' :: _) = Just []
    go (c :: cs) = map (c ::) (go cs)

containsDotDot : List String -> Bool
containsDotDot [] = False
containsDotDot (s :: ss) = s == ".." || containsDotDot ss

||| True if `path` (already relative, with the route's mount prefix
||| stripped) can't escape the directory it's served from: no ".."
||| segment, and not itself absolute. Lexical only - doesn't rule out a
||| symlink *inside* the directory pointing back out of it (see
||| `staticHandler`'s own defense against that).
export
isSafeRelativePath : String -> Bool
isSafeRelativePath path =
  not (isPrefixOf "/" path) &&
  not (containsDotDot (Data.List1.forget (Data.String.split (== '/') path)))

-- A canonicalized path, represented as a segment stack rather than a
-- string, so ".."/"." can be interpreted correctly (popping/no-op)
-- instead of surviving as literal, meaningless path text - see
-- `pushSegment`. `fst` records whether the path is absolute.
0 PathState : Type
PathState = (Bool, List String)

-- Splits a path into its meaningful segments - "." and empty segments
-- (from a leading/trailing/doubled '/') carry no information and are
-- dropped here; ".." is kept, since it needs pop semantics (see
-- `pushSegment`), not to be silently dropped like the others.
rawSegments : String -> List String
rawSegments path = filter (\s => s /= "" && s /= ".") (Data.List1.forget (Data.String.split (== '/') path))

isAbsolutePath : String -> Bool
isAbsolutePath = isPrefixOf "/"

renderPath : PathState -> String
renderPath (isAbs, stack) =
  let body := joinBy "/" stack
   in if isAbs then "/" ++ body else body

-- ".." pops the last pushed segment (a no-op at the top, rather than
-- escaping above it); anything else just pushes normally. This is the
-- only place ".." is interpreted - by the time a path reaches here it's
-- either from `root`/the request path (already guaranteed ".."-free by
-- `isSafeRelativePath`) or a symlink's own target, which is untrusted
-- and can legitimately contain one.
pushSegment : List String -> String -> List String
pushSegment stack ".." = case stack of
  []          => []
  (_ :: rest) => rest
pushSegment stack s = stack ++ [s]

-- Everything but the last segment - the directory containing whatever
-- that last segment names, used to resolve a *relative* symlink target
-- against the link's own location rather than the caller's.
dropLastSegment : List String -> List String
dropLastSegment stack = case reverse stack of
  []        => []
  (_ :: rs) => reverse rs

||| How many symlink *follows* `resolveWorklist` allows in a single walk
||| before giving up and failing closed - defends a symlink cycle (or a
||| deliberately pathological legitimate chain, which looks identical
||| from here) from becoming an infinite loop. Counts only actual
||| symlink dereferences, matching Linux's own kernel-enforced
||| MAXSYMLINKS - *not* every path segment consumed, so a legitimately
||| deep request path with no symlinks in it at all is never spuriously
||| rejected by this budget.
maxSymlinkDepth : Nat
maxSymlinkDepth = 40

-- Resolves `segments` onto `state` one segment at a time, checking the
-- *resulting accumulated path* for being a symlink after every single
-- push - whether that segment came from the caller's own path or was
-- just spliced in from a symlink target discovered a moment ago. This
-- is namei()-style resolution: a single worklist, rather than two loops
-- of different granularity (one over the caller's own segments, one
-- that bulk-substituted a discovered symlink's *whole* target before a
-- single check of the result) - the two-loop shape is what let an
-- intermediate segment introduced by a multi-segment symlink target
-- (e.g. "jump/secret.txt", where "jump" is itself a symlink pointing
-- outside `root`) go unchecked and unresolved in an earlier version of
-- this function.
--
-- A relative target is resolved against the *link's own* directory
-- (`dropLastSegment stack'`, not the caller's), matching `readlink`
-- semantics; an absolute target discards everything resolved so far and
-- restarts from "/", matching how the OS treats one. Either way the
-- target's own segments are pushed onto the *front* of the remaining
-- queue, one at a time - not folded in bulk - so any symlink or ".." the
-- target itself contains gets exactly the same per-segment check as
-- everything else.
--
-- `Nothing` means the walk exceeded `maxSymlinkDepth` symlink follows -
-- a real cycle, or a chain too long to distinguish from one - or hit an
-- empty symlink target (`openFile` would never succeed on one anyway,
-- so fail closed rather than guess what it should mean). The caller
-- must treat this as failure and stop, not continue with a partial
-- result: continuing with incomplete resolution could itself mask an
-- escape.
resolveWorklist : (linksLeft : Nat) -> PathState -> List String -> AppProg (Maybe PathState)
resolveWorklist _         state []              = pure (Just state)
resolveWorklist linksLeft (isAbs, stack) (s :: rest) = do
  let stack' = pushSegment stack s
  elink <- attempt (the (AppProg ByteString) (readlink (renderPath (isAbs, stack'))))
  case elink of
    Left _      => resolveWorklist linksLeft (isAbs, stack') rest
    Right bytes => case linksLeft of
      Z   => pure Nothing
      S k => case toString bytes of
        "" => pure Nothing
        target =>
          if isAbsolutePath target
            then resolveWorklist k (True, []) (rawSegments target ++ rest)
            else resolveWorklist k (isAbs, dropLastSegment stack') (rawSegments target ++ rest)

-- Canonicalizes `path` starting from `start`, following every symlink
-- chain (transitively) it introduces along the way - see
-- `resolveWorklist`. `Nothing` means the chain was too deep/cyclic to
-- resolve; the caller must fail closed.
canonicalizeFrom : PathState -> String -> AppProg (Maybe PathState)
canonicalizeFrom start path = resolveWorklist maxSymlinkDepth start (rawSegments path)

canonicalize : String -> AppProg (Maybe PathState)
canonicalize path = canonicalizeFrom (isAbsolutePath path, []) path

isPrefixOfSegments : List String -> List String -> Bool
isPrefixOfSegments []        _         = True
isPrefixOfSegments _         []        = False
isPrefixOfSegments (x :: xs) (y :: ys) = x == y && isPrefixOfSegments xs ys

-- True if `resolved` (already canonicalized) is `root` itself or
-- genuinely nested under it - segment-wise, not merely string-prefixed,
-- so a root of "public" doesn't false-positive-accept an escape to a
-- sibling directory like "public-evil".
underRoot : (root, resolved : PathState) -> Bool
underRoot (rootAbs, rootStack) (resAbs, resStack) =
  rootAbs == resAbs && isPrefixOfSegments rootStack resStack

||| Serves files from `root`. The route must capture the requested
||| relative path under a path param named "path" (a splat segment does
||| this - see the module docstring); a missing/unsafe path renders
||| 404/403, an existing file streams with a Content-Type from `mimeFor`.
|||
||| Guards against two things `isSafeRelativePath`'s lexical check alone
||| doesn't catch: a symlink somewhere under `root` that points outside
||| it (both `root` and the resolved request path are walked through
||| `canonicalize`, following any symlinks found, before the containment
||| check), and the TOCTOU race a naive "open to check existence, close,
||| then reopen by path to stream" would have - there's exactly one
||| `openFile` call here, and the same `Fd` it returns is reused directly
||| for the actual stream rather than reopened by path.
|||
||| This isn't airtight: the containment check and the real `openFile`
||| are still two separate syscalls, so a symlink swapped in the narrow
||| window between them isn't caught (the same residual gap `realpath`-
||| based checks in most languages have too - closing it fully needs
||| kernel support this dependency stack doesn't have, e.g. Linux 5.6+'s
||| `openat2`/`RESOLVE_NO_SYMLINKS`). This defends against a symlink
||| placed once by whoever populates the served directory, not an
||| attacker who can also race the filesystem underneath a live request.
export
staticHandler : (root : String) -> (mimeFor : String -> String) -> Handler
staticHandler root mimeFor ctx =
  case getParam "path" ctx.pathParams of
    Nothing => pure (setStatus 404 (sendText "Not Found" ctx))
    Just reqPath =>
      if not (isSafeRelativePath reqPath)
        then pure (setStatus 403 (sendText "Forbidden" ctx))
        else do
          -- root is operator-controlled, not attacker input - if it
          -- can't be resolved (a pathologically deep or literally
          -- cyclic root symlink) that's a deployment fault, not this
          -- particular request looking like an attack, so it's a 500
          -- via the framework's own error channel, not folded into the
          -- 403 path below.
          mRoot <- canonicalize root
          case mRoot of
            Nothing => throw (MkAppError 500 "Internal Server Error")
            Just canonicalRoot => do
              mResolved <- canonicalizeFrom canonicalRoot reqPath
              case mResolved of
                Nothing => pure (setStatus 403 (sendText "Forbidden" ctx))
                Just resolved =>
                  if not (underRoot canonicalRoot resolved)
                    then pure (setStatus 403 (sendText "Forbidden" ctx))
                    else do
                      let filePath := root ++ "/" ++ reqPath
                      -- Check existence upfront so a missing file
                      -- renders a clean 404 rather than letting the
                      -- streaming read fail later, past the point a
                      -- status code can still be chosen - and reuse
                      -- this exact Fd for the stream below instead of
                      -- reopening by path (see this handler's doc).
                      opened <- attempt (the (AppProg Fd) (openFile filePath O_RDONLY 0))
                      case opened of
                        Left _   => pure (setStatus 404 (sendText "Not Found" ctx))
                        Right fd => do
                          let mime := mimeFor (extensionOf reqPath)
                          pure $ setHeader "Content-Type" mime $
                            sendStream Nothing (resource (pure fd) (\f => bytes f 0xffff)) ctx
