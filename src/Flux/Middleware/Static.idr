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

pushAll : List String -> List String -> List String
pushAll = foldl pushSegment

-- Everything but the last segment - the directory containing whatever
-- that last segment names, used to resolve a *relative* symlink target
-- against the link's own location rather than the caller's.
dropLastSegment : List String -> List String
dropLastSegment stack = case reverse stack of
  []        => []
  (_ :: rs) => reverse rs

||| How many symlink indirections `resolveLinks` follows before giving up
||| and treating the result as final - defends a symlink cycle from
||| becoming an infinite loop. Matches Linux's own kernel-enforced
||| MAXSYMLINKS.
maxSymlinkDepth : Nat
maxSymlinkDepth = 40

-- Follows any symlink chain rooted at `state` - bounded by `budget` -
-- until the result is symlink-free, properly collapsing any ".."/"." a
-- relative symlink target contains (relative to the *link's own*
-- directory, not the caller's - see `dropLastSegment`).
--
-- `readlink` failing (the overwhelmingly common case: this isn't a
-- symlink) is treated the same as anything else that goes wrong reading
-- it - the path is kept as-is. This only exists to compute the true
-- destination for `staticHandler`'s containment check; a path that
-- doesn't actually exist is caught later, when the real `openFile` for
-- it fails.
resolveLinks : Nat -> PathState -> AppProg PathState
resolveLinks Z     state = pure state
resolveLinks (S k) state@(isAbs, stack) = do
  elink <- attempt (the (AppProg ByteString) (readlink (renderPath state)))
  case elink of
    Left _      => pure state
    Right bytes =>
      let target := toString bytes
       in if isAbsolutePath target
            then resolveLinks k (True, pushAll [] (rawSegments target))
            else resolveLinks k (isAbs, pushAll (dropLastSegment stack) (rawSegments target))

-- Appends every segment of `path` onto `start` in turn, following any
-- symlink chain after each one (see `resolveLinks`), building up the
-- fully symlink-resolved form.
canonicalizeFrom : PathState -> String -> AppProg PathState
canonicalizeFrom start path = go start (rawSegments path)
  where
    go : PathState -> List String -> AppProg PathState
    go state []        = pure state
    go (isAbs, stack) (s :: ss) = do
      state' <- resolveLinks maxSymlinkDepth (isAbs, pushSegment stack s)
      go state' ss

canonicalize : String -> AppProg PathState
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
          canonicalRoot <- canonicalize root
          resolved      <- canonicalizeFrom canonicalRoot reqPath
          if not (underRoot canonicalRoot resolved)
            then pure (setStatus 403 (sendText "Forbidden" ctx))
            else do
              let filePath := root ++ "/" ++ reqPath
              -- Check existence upfront so a missing file renders a
              -- clean 404 rather than letting the streaming read fail
              -- later, past the point a status code can still be
              -- chosen - and reuse this exact Fd for the stream below
              -- instead of reopening by path (see this handler's doc).
              opened <- attempt (the (AppProg Fd) (openFile filePath O_RDONLY 0))
              case opened of
                Left _   => pure (setStatus 404 (sendText "Not Found" ctx))
                Right fd => do
                  let mime := mimeFor (extensionOf reqPath)
                  pure $ setHeader "Content-Type" mime $
                    sendStream Nothing (resource (pure fd) (\f => bytes f 0xffff)) ctx
