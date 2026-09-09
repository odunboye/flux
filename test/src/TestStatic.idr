module TestStatic

import Flux.Middleware.Static
import Flux.Core.HTTP
import Flux.Core.Middleware
import Flux.Core.Router
import Data.IORef
import Data.SortedMap
import System

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
setupFixture : IO ()
setupFixture = do
  _ <- system "rm -rf /tmp/flux-static-test"
  _ <- system "mkdir -p \{fixtureRoot}"
  _ <- system "echo secret > /tmp/flux-static-test/outside.txt"
  _ <- system "ln -s ../outside.txt \{fixtureRoot}/escape.txt"
  _ <- system "echo hello > \{fixtureRoot}/inside.txt"
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

-- Run all static-serving tests
export
runAllTests : IO (List (String, Bool))
runAllTests = do
  escapeRejected <- testRejectsSymlinkEscape
  nestedServed   <- testServesGenuinelyNestedFile
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
    ("servesGenuinelyNestedFile", nestedServed)
    ]
