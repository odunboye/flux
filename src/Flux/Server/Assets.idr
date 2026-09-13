||| Native serving of a Flux-built public asset bundle. Mount these exact routes
||| after application RPC routes. No development proxy, watcher or HMR injection.
module Flux.Server.Assets

import Flux.Core.Router
import Flux.Middleware.Static
import System
import System.File
import Data.String
import Data.List1

%default covering

safeAsset : String -> Bool
safeAsset path = path /= "" && isSafeRelativePath path &&
  all (\segment => segment /= "" && not (isPrefixOf "." segment))
      (forget (split (== '/') path)) &&
  all (\c => (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
             (c >= '0' && c <= '9') || elem c ['/', '.', '-', '_']) (unpack path)

asset : String -> String -> Handler
asset root name ctx = do
  response <- staticHandler root mime ({ pathParams := MkParams (fromList [("path", name)]) } ctx)
  pure (setHeader "X-Flux-Assets" "1" (setHeader "X-Content-Type-Options" "nosniff"
    (setHeader "Cache-Control" "no-cache" response)))
  where
  mime : String -> String
  mime "woff" = "font/woff"
  mime "woff2" = "font/woff2"
  mime "ttf" = "font/ttf"
  mime "webp" = "image/webp"
  mime "webmanifest" = "application/manifest+json"
  mime ext = defaultMimeFor ext

||| Disabled unless FLUX_PUBLIC_DIR is set. flux run points this at a verified,
||| immutable build artifact, never the source tree. The private manifest names
||| exactly which files can be served; directories and unknown paths stay 404.
export
webAssetsFromEnv : IO (Router Handler)
webAssetsFromEnv = do
  Just root <- getEnv "FLUX_PUBLIC_DIR" | Nothing => pure empty
  Right content <- System.File.ReadWrite.readFile (root ++ "/.flux-assets")
    | Left _ => putStrLn "Cannot read the Flux public asset manifest" >> exitFailure
  let names = lines content
  unless (length names <= 4096 && all safeAsset names && elem "index.html" names && elem "app.js" names)
    (putStrLn "Invalid Flux public asset manifest" >> exitFailure)
  pure (foldl (\router, name => get ("/" ++ name) (asset root name) router)
              (get "/" (asset root "index.html") empty) names)
