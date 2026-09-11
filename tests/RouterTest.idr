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
  assert "malformed escape" (case parseLocation "/bad%2" of Nothing => True; _ => False)
  let moved = applyNav (Push (User "a")) (initNav Home)
  assert "push" (case moved.current of User "a" => True; _ => False)
  assert "back" (case (applyNav (Back 1) moved).current of Home => True; _ => False)
  putStrLn "Router tests passed"
