||| Serves files from a directory on disk. Mount it under a route with a
||| splat segment so nested paths work, e.g.:
||| `get "/static/*path" (staticHandler "public" defaultMimeFor) router`.
module Flux.Middleware.Static

import public Flux.Core.HTTP
import public Flux.Core.Middleware
import Data.List1
import Data.String
import System.File

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
||| segment, and not itself absolute.
export
isSafeRelativePath : String -> Bool
isSafeRelativePath path =
  not (isPrefixOf "/" path) &&
  not (containsDotDot (Data.List1.forget (Data.String.split (== '/') path)))

||| Serves files from `root`. The route must capture the requested
||| relative path under a path param named "path" (a splat segment does
||| this - see the module docstring); a missing/unsafe path renders
||| 404/403, an existing file streams with a Content-Type from `mimeFor`.
export
staticHandler : (root : String) -> (mimeFor : String -> String) -> Handler
staticHandler root mimeFor ctx =
  case getParam "path" ctx.pathParams of
    Nothing => pure (setStatus 404 (sendText "Not Found" ctx))
    Just reqPath =>
      if not (isSafeRelativePath reqPath)
        then pure (setStatus 403 (sendText "Forbidden" ctx))
        else do
          let filePath := root ++ "/" ++ reqPath
          -- Check existence upfront (open then immediately close) so a
          -- missing file renders a clean 404 rather than letting the
          -- streaming read fail later, past the point a status code can
          -- still be chosen.
          opened <- liftIO (openFile filePath Read)
          case opened of
            Left _   => pure (setStatus 404 (sendText "Not Found" ctx))
            Right fh => do
              liftIO (closeFile fh)
              let mime := mimeFor (extensionOf reqPath)
              pure $ setHeader "Content-Type" mime $ sendStream Nothing (readBytes filePath) ctx
