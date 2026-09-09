module TestStatic

import Flux.Middleware.Static
import Flux.Core.HTTP
import Flux.Core.Middleware
import Flux.Core.Router
import Data.IORef
import Data.SortedMap
import System
import System.Directory

%default covering

-- extensionOf

export
testExtensionOfSimple : Bool
testExtensionOfSimple = extensionOf "app.js" == "js"

export
testExtensionOfNested : Bool
testExtensionOfNested = extensionOf "css/theme.min.css" == "css"

export
testExtensionOfNone : Bool
testExtensionOfNone = extensionOf "README" == ""

-- defaultMimeFor

export
testMimeForKnown : Bool
testMimeForKnown =
  defaultMimeFor "html" == "text/html" &&
  defaultMimeFor "JS" == "application/javascript" &&
  defaultMimeFor "png" == "image/png"

export
testMimeForUnknown : Bool
testMimeForUnknown = defaultMimeFor "xyz123" == "application/octet-stream"

-- isSafeRelativePath: this is the security-critical check, so exercise it
-- thoroughly - a client fully controls this string via the request URI.

export
testSafeSimplePath : Bool
testSafeSimplePath = isSafeRelativePath "js/app.js" == True

export
testRejectsParentTraversal : Bool
testRejectsParentTraversal = isSafeRelativePath "../../etc/passwd" == False

export
testRejectsEmbeddedTraversal : Bool
testRejectsEmbeddedTraversal = isSafeRelativePath "js/../../../etc/passwd" == False

export
testRejectsAbsolutePath : Bool
testRejectsAbsolutePath = isSafeRelativePath "/etc/passwd" == False

export
testAllowsDotInFilename : Bool
testAllowsDotInFilename = isSafeRelativePath "file..txt" == True

export
testAllowsSingleDotSegment : Bool
testAllowsSingleDotSegment = isSafeRelativePath "./app.js" == True

--------------------------------------------------------------------------------
-- staticHandler: symlink escape is rejected, a genuinely nested file
-- still serves - exercises real filesystem state (a real symlink), not
-- just the lexical isSafeRelativePath check above.
--------------------------------------------------------------------------------

fixtureRoot : String
fixtureRoot = "/tmp/flux-static-test/root"

-- root/escape.txt -> ../outside.txt (a real symlink pointing outside
-- root); root/inside.txt is a genuinely nested, ordinary file.
--
-- root/jump -> /tmp/flux-static-test (absolute symlink outside root);
-- root/indirect.txt -> jump/outside.txt (relative, two-segment target
-- whose *first* segment, "jump", is itself a symlink pointing outside
-- root) - the shape that bypassed an earlier version of this
-- containment check: a bulk substitute-then-check-once walk never gave
-- "jump" its own check.
--
-- root/alias -> subdir (a symlink to a directory fully *inside* root) -
-- a legitimate case the per-segment checking must not over-reject.
setupFixture : IO ()
setupFixture = do
  _ <- system "rm -rf /tmp/flux-static-test"
  _ <- system "mkdir -p \{fixtureRoot}"
  _ <- system "echo secret > /tmp/flux-static-test/outside.txt"
  _ <- system "ln -s ../outside.txt \{fixtureRoot}/escape.txt"
  _ <- system "ln -s /tmp/flux-static-test \{fixtureRoot}/jump"
  _ <- system "ln -s jump/outside.txt \{fixtureRoot}/indirect.txt"
  _ <- system "echo hello > \{fixtureRoot}/inside.txt"
  _ <- system "mkdir -p \{fixtureRoot}/subdir"
  _ <- system "echo aliased > \{fixtureRoot}/subdir/file.txt"
  _ <- system "ln -s subdir \{fixtureRoot}/alias"
  pure ()

dummyRequest : Request
dummyRequest = R GET "/" empty V11 empty 0 Nothing (pure (pure ()))

withPath : String -> Context
withPath p = { pathParams := MkParams (fromList [("path", p)]) } (emptyContext dummyRequest)

-- Runs a Handler for real, via the async runtime.
runHandler : Handler -> Context -> IO (Maybe Context)
runHandler h ctx = do
  ref <- newIORef Nothing
  runProg $
    handleErrors
      (\case
        Here e         => liftIO (putStrLn "runHandler: unexpected Errno: \{e}")
        There (Here e) => liftIO (putStrLn "runHandler: unexpected AppError: \{e.message}"))
      (foreach (\v => liftIO (writeIORef ref (Just v))) (eval (h ctx)))
  readIORef ref

withHeadPath : String -> Context
withHeadPath p =
  { pathParams := MkParams (fromList [("path", p)]) }
  (emptyContext ({ method := HEAD } dummyRequest))

-- Fully renders a Context to wire bytes, discarding the output - drives
-- render's own body-suppression/draining logic for real, the same way
-- the real driver (respondWith) would, rather than just calling
-- staticHandler and stopping at the resulting Context (which never
-- actually runs - and so never actually cleans up - a Streamed body).
renderAndDrain : Context -> IO ()
renderAndDrain ctx =
  runProg $
    handleErrors
      (\case
        Here e         => liftIO (putStrLn "renderAndDrain: unexpected Errno: \{e}")
        There (Here e) => liftIO (putStrLn "renderAndDrain: unexpected HTTPErr: \{e}"))
      (ignore (foreach (\_ => pure ()) (render ctx)))

-- Open file descriptor count for this process, via /proc/self/fd
-- (Linux - matches CI; not available on Darwin, where this returns
-- Nothing and the one test using it passes trivially, the same
-- graceful-degradation precedent as Flux.Server.Health.memoryCheck).
fdCount : IO (Maybe Nat)
fdCount = do
  Right entries <- listDir "/proc/self/fd" | Left _ => pure Nothing
  pure (Just (length entries))

export
testRejectsSymlinkEscape : IO Bool
testRejectsSymlinkEscape = do
  setupFixture
  Just ctx <- runHandler (staticHandler fixtureRoot defaultMimeFor) (withPath "escape.txt")
    | Nothing => pure False
  pure (ctx.statusCode == 403)

export
testServesGenuinelyNestedFile : IO Bool
testServesGenuinelyNestedFile = do
  setupFixture
  Just ctx <- runHandler (staticHandler fixtureRoot defaultMimeFor) (withPath "inside.txt")
    | Nothing => pure False
  pure (ctx.statusCode /= 403 && ctx.statusCode /= 404)

-- Regression test for a real bypass found in an earlier version of the
-- containment check: a symlink whose target is itself a multi-segment
-- path with an intermediate symlink component (see setupFixture) was
-- never individually checked, because the old code substituted a
-- discovered target's segments in bulk and checked the result only
-- once. The fix unifies request-path and symlink-target segments into
-- one worklist, checking after every single push.
export
testRejectsIndirectSymlinkEscape : IO Bool
testRejectsIndirectSymlinkEscape = do
  setupFixture
  Just ctx <- runHandler (staticHandler fixtureRoot defaultMimeFor) (withPath "indirect.txt")
    | Nothing => pure False
  pure (ctx.statusCode == 403)

-- Positive case: a symlinked *directory* fully inside root, accessed
-- via a multi-segment path through it, must still serve normally - the
-- new per-segment checking must not over-reject a legitimate symlink
-- that never leaves root.
export
testServesThroughSymlinkedDirInsideRoot : IO Bool
testServesThroughSymlinkedDirInsideRoot = do
  setupFixture
  Just ctx <- runHandler (staticHandler fixtureRoot defaultMimeFor) (withPath "alias/file.txt")
    | Nothing => pure False
  pure (ctx.statusCode /= 403 && ctx.statusCode /= 404)

-- Regression test for a real fd leak: staticHandler opens a file
-- descriptor and wraps it in a Streamed body whose cleanup only runs
-- when that stream is actually pulled to completion (see render's own
-- doc comment). A HEAD request's response never used to touch
-- ctx.respBody at all - render's HEAD/204/304 suppression just emitted
-- the header block and stopped - so the fd never got closed. Only
-- checked where /proc/self/fd is available (see fdCount) - passes
-- trivially elsewhere rather than claiming a result it can't verify.
export
testHeadRequestDoesNotLeakFd : IO Bool
testHeadRequestDoesNotLeakFd = do
  setupFixture
  Nothing <- fdCount | Just _ => runCheck
  pure True
  where
    oneRequest : IO ()
    oneRequest = do
      Just ctx <- runHandler (staticHandler fixtureRoot defaultMimeFor) (withHeadPath "inside.txt")
        | Nothing => pure ()
      renderAndDrain ctx
    runCheck : IO Bool
    runCheck = do
      for_ [the Nat 1 .. 5] (const oneRequest)
      Just before <- fdCount | Nothing => pure True
      for_ [the Nat 1 .. 20] (const oneRequest)
      Just after <- fdCount | Nothing => pure True
      pure (after <= before)

-- Run all static-serving tests
export
runAllTests : IO (List (String, Bool))
runAllTests = do
  escapeRejected         <- testRejectsSymlinkEscape
  nestedServed           <- testServesGenuinelyNestedFile
  indirectEscapeRejected <- testRejectsIndirectSymlinkEscape
  symlinkedDirServed     <- testServesThroughSymlinkedDirInsideRoot
  headFdOk               <- testHeadRequestDoesNotLeakFd
  pure [
    ("extensionOfSimple", testExtensionOfSimple),
    ("extensionOfNested", testExtensionOfNested),
    ("extensionOfNone", testExtensionOfNone),
    ("mimeForKnown", testMimeForKnown),
    ("mimeForUnknown", testMimeForUnknown),
    ("safeSimplePath", testSafeSimplePath),
    ("rejectsParentTraversal", testRejectsParentTraversal),
    ("rejectsEmbeddedTraversal", testRejectsEmbeddedTraversal),
    ("rejectsAbsolutePath", testRejectsAbsolutePath),
    ("allowsDotInFilename", testAllowsDotInFilename),
    ("allowsSingleDotSegment", testAllowsSingleDotSegment),
    ("rejectsSymlinkEscape", escapeRejected),
    ("servesGenuinelyNestedFile", nestedServed),
    ("rejectsIndirectSymlinkEscape", indirectEscapeRejected),
    ("servesThroughSymlinkedDirInsideRoot", symlinkedDirServed),
    ("headRequestDoesNotLeakFd", headFdOk)
    ]
