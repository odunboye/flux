module Main

import System
import Iris.Router.Types

data Route = Home | User String | Missing

Router Route where
  toUrl Home = "/"
  toUrl (User id) = "/users/" ++ id
  toUrl Missing = "/404"
  fromUrl raw = do
    location <- parseLocation raw
    case location.path == "/" of
      True => Just Home
      False => case matchPath "/users/:id" location.path of
                 Just [("id", id)] => Just (User id)
                 _ => Nothing

assert : String -> Bool -> IO ()
assert _ True = pure ()
assert label False = do
  putStrLn ("Router test failed: " ++ label)
  exitFailure

main : IO ()
main = do
  case parseLocation "/users/alice?tab=posts%20and%20replies&page=2#latest" of
    Nothing => assert "location parsing" False
    Just location => do
      assert "path" (location.path == "/users/alice")
      assert "query decoding" (queryParam "tab" location == Just "posts and replies")
      assert "fragment" (location.fragment == Just "latest")
  assert "path parameter" (matchPath "/users/:id" "/users/bob" == Just [("id", "bob")])
  assert "route parsing" (case fromUrl {route=Route} "/users/bob" of Just (User "bob") => True; _ => False)
  assert "not found" (case fromUrl {route=Route} "/unknown" of Nothing => True; _ => False)
  assert "explicit not-found result"
    (case resolveRoute {route=Route} "/unknown?q=1" of NotFound _ => True; _ => False)
  let encoded = renderLocation (MkLocation "/café/✓" [("q", "日本 tea")] (Just "résumé"))
  assert "location encoding"
    (encoded == "/caf%C3%A9/%E2%9C%93?q=%E6%97%A5%E6%9C%AC%20tea#r%C3%A9sum%C3%A9")
  assert "location round trip"
    (case parseLocation encoded of
       Just location => location.path == "/café/✓" && queryParam "q" location == Just "日本 tea"
       _ => False)
  assert "base path" (withBasePath "/iris" "/users/a" == "/iris/users/a")
  assert "strip base path" (stripBasePath "/iris" "/iris/users/a" == Just "/users/a")
  assert "reject wrong base" (stripBasePath "/iris" "/other/users/a" == Nothing)
  assert "navigation guard allow"
    (case applyNavigationGuard (\route => Allow route) Home of Just Home => True; _ => False)
  assert "navigation guard block"
    (case applyNavigationGuard (const Block) Home of Nothing => True; _ => False)
  assert "UTF-8 path decoding"
    (case parseLocation "/caf%C3%A9/%E2%9C%93" of
       Just location => location.path == "/café/✓"
       _ => False)
  assert "UTF-8 query decoding"
    (case parseLocation "/?q=%E6%97%A5%E6%9C%AC" of
       Just location => queryParam "q" location == Just "日本"
       _ => False)
  assert "malformed escape" (case parseLocation "/bad%2" of Nothing => True; _ => False)
  assert "overlong UTF-8 rejected" (case parseLocation "/%C0%AF" of Nothing => True; _ => False)
  assert "surrogate UTF-8 rejected" (case parseLocation "/%ED%A0%80" of Nothing => True; _ => False)
  assert "out-of-range UTF-8 rejected" (case parseLocation "/%F4%90%80%80" of Nothing => True; _ => False)
  let moved = applyNav (Push (User "a")) (initNav Home)
  assert "push" (case moved.current of User "a" => True; _ => False)
  assert "back" (case (applyNav (Back 1) moved).current of Home => True; _ => False)
  putStrLn "Router tests passed"
