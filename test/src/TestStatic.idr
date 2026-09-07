module TestStatic

import Flux.Middleware.Static

%default total

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

-- Run all static-serving tests
export
runAllTests : List (String, Bool)
runAllTests = [
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
  ("allowsSingleDotSegment", testAllowsSingleDotSegment)
  ]
