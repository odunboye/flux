module TodoUI

import Client
import Flux.Platform.Client.Auth as Auth
import Iris.App
import Iris.Widget
import Iris.Platform.Event
import Data.List

%default covering

public export
record Model where
  constructor MkModel
  todos : List TodoView
  nextId : Maybe String
  draft : String
  editing : Maybe TodoView
  confirmDelete : Maybe String
  busy : Bool
  suspended : Bool
  loaded : Bool
  notice : String
  username : String
  password : String
  session : Maybe Auth.Session
  pendingLogout : Maybe String
  epoch : Nat

public export
data Result = Listed Bool (Either RpcError ListTodosResponse)
            | Created (Either RpcError TodoView)
            | Found (Either RpcError FindTodoResponse)
            | Changed (Either RpcError FindTodoResponse)
            | Deleted String (Either RpcError DeleteTodoResponse)
            | SignedIn (Either RpcError Auth.Session)
            | Registered (Either RpcError Auth.Account)
            | SignedOut (Either RpcError JSON)

public export
data Msg = Draft String | Add | Refresh | More | Edit String | Save | Cancel | Interrupted | Resumed
         | Toggle String | AskDelete String | Keep | Delete String
         | Username String | Password String | SignIn | Register | SignOut | RetrySignOut
         | Finished Nat Result

emptyModel : Nat -> String -> Model
emptyModel epoch notice = MkModel [] Nothing "" Nothing Nothing False False False notice "" "" Nothing Nothing epoch

errorText : RpcError -> String
errorText (RemoteError status code message) = "Request rejected (" ++ show status ++ ", " ++ code ++ "): " ++ message
errorText (InvalidResponse _) = "Invalid server response. Refresh before retrying a write."
errorText (TransportFailure _) = "Connection failed. Refresh before retrying a write."

failed : Model -> RpcError -> (Model, Cmd Msg)
failed m err = case (m.session, err) of
  (Just _, RemoteError 401 _ _) => (emptyModel (S m.epoch) "Session expired or revoked. Sign in.", none)
  _ => ({ busy := False, password := "", notice := errorText err } m, none)

merge : List TodoView -> List TodoView -> List TodoView
merge old incoming = filter (\t => not (any (\n => n.id == t.id) incoming)) old ++ incoming

validTitle : String -> Bool
validTitle value = value /= "" && length (unpack value) <= 128

act : Client -> Msg -> Model -> (Model, Cmd Msg)
act client (Draft value) m = ({ draft := value } m, none)
act client Refresh m = ({ busy := True, notice := "Refreshing..." } m, listTodos client (MkListTodosRequest Nothing) (Finished m.epoch . Listed False))
act client More m = case m.nextId of
  Nothing => (m, none)
  Just cursor => ({ busy := True, notice := "Loading more..." } m, listTodos client (MkListTodosRequest (Just cursor)) (Finished m.epoch . Listed True))
act client Add m =
  if validTitle m.draft
    then ({ busy := True, notice := "Creating..." } m, createTodo client (MkCreateTodoRequest m.draft) (Finished m.epoch . Created))
    else ({ notice := "Title must contain 1 to 128 characters." } m, none)
act client (Edit tid) m = ({ busy := True, notice := "Loading todo..." } m, getTodo client (MkTodoIdRequest tid) (Finished m.epoch . Found))
act client Save m = case m.editing of
  Nothing => (m, none)
  Just todo => if validTitle m.draft
    then ({ busy := True, notice := "Saving..." } m, updateTodo client (MkUpdateTodoRequest todo.done todo.id m.draft) (Finished m.epoch . Changed))
    else ({ notice := "Title must contain 1 to 128 characters." } m, none)
act _ Cancel m = ({ editing := Nothing, draft := "", notice := "Edit cancelled." } m, none)
act client (Toggle tid) m = ({ busy := True, notice := "Updating..." } m, toggleTodo client (MkTodoIdRequest tid) (Finished m.epoch . Changed))
act _ (AskDelete tid) m = ({ confirmDelete := Just tid } m, none)
act _ Keep m = ({ confirmDelete := Nothing } m, none)
act client (Delete tid) m = case m.confirmDelete of
  Just confirmed => if confirmed == tid
    then ({ busy := True, notice := "Deleting..." } m, deleteTodo client (MkTodoIdRequest tid) (Finished m.epoch . Deleted tid))
    else (m, none)
  Nothing => (m, none)
act _ _ m = (m, none)

finish : Client -> Result -> Model -> (Model, Cmd Msg)
finish client (SignedIn (Right session)) m =
  ({ session := Just session, todos := [], nextId := Nothing, draft := "", loaded := False,
     password := "", busy := True, notice := "Loading..." } m,
   listTodos (withBearer session.token client) (MkListTodosRequest Nothing) (Finished m.epoch . Listed False))
finish _ (SignedIn (Left err)) m = failed m err
finish _ (Registered (Left err)) m = failed m err
finish _ (Registered (Right account)) m = ({ busy := False, password := "", username := account.username, notice := "Account created. Sign in." } m, none)
finish _ (SignedOut (Right _)) m = (emptyModel (S m.epoch) "Signed out.", none)
finish _ (SignedOut (Left (RemoteError 401 _ _))) m = (emptyModel (S m.epoch) "Signed out.", none)
finish _ (SignedOut (Left _)) m = ({ busy := False, notice := "Local data cleared. Server logout unconfirmed; retry sign out." } m, none)
finish _ (Listed append (Left err)) m = failed m err
finish _ (Listed append (Right page)) m =
  ({ todos := if append then merge m.todos page.todos else page.todos,
     nextId := page.nextId, busy := False, loaded := True, notice := "Ready." } m, none)
finish _ (Created (Left err)) m = failed m err
finish _ (Created (Right todo)) m =
  ({ todos := merge m.todos [todo], draft := "", busy := False, notice := "Created." } m, none)
finish _ (Found (Left err)) m = failed m err
finish _ (Found (Right result)) m = case result.todo of
  Nothing => ({ busy := False, notice := "Todo no longer exists. Refresh the list." } m, none)
  Just todo => ({ editing := Just todo, draft := todo.title, busy := False, notice := "Editing." } m, none)
finish _ (Changed (Left err)) m = failed m err
finish _ (Changed (Right result)) m = case result.todo of
  Nothing => ({ busy := False, notice := "Todo no longer exists. Refresh the list." } m, none)
  Just todo => ({ todos := merge m.todos [todo], editing := Nothing,
     draft := case m.editing of Nothing => m.draft; Just _ => "", busy := False, notice := "Saved." } m, none)
finish _ (Deleted tid (Left err)) m = failed m err
finish _ (Deleted tid (Right result)) m =
  ({ todos := filter (\t => t.id /= tid) m.todos, confirmDelete := Nothing,
     busy := False, notice := if result.deleted then "Deleted." else "Already deleted." } m, none)

public export
update : Client -> Msg -> Model -> (Model, Cmd Msg)
update _ Interrupted m =
  ({ busy := False, suspended := True, password := "", epoch := S m.epoch,
     notice := if m.busy then "Request interrupted. Refresh or explicitly retry after resuming." else m.notice } m, none)
update _ Resumed m = ({ suspended := False } m, none)
update client (Finished expected result) m =
  if expected /= m.epoch || m.suspended then (m, none) else finish client result m
-- Logout is allowed even while a request is busy. Clear BEFORE doing network IO;
-- every older callback carries a different epoch and can never repopulate state.
update client SignOut m = case m.session of
  Nothing => (m, none)
  Just session => if m.suspended then (m, none) else
    let next = { busy := True, pendingLogout := Just session.token } (emptyModel (S m.epoch) "Signing out...") in
      (next, Auth.logout (withBearer session.token client) (Finished next.epoch . SignedOut))
update client RetrySignOut m = case m.pendingLogout of
  Nothing => (m, none)
  Just token => if m.busy || m.suspended then (m, none) else
    ({ busy := True, notice := "Signing out..." } m, Auth.logout (withBearer token client) (Finished m.epoch . SignedOut))
update client msg m =
  if m.busy || m.suspended || isJust m.pendingLogout then (m, none) else case m.session of
    Just session => act (withBearer session.token client) msg m
    Nothing => case msg of
      Username value => ({ username := value } m, none)
      Password value => ({ password := value } m, none)
      SignIn =>
        let next = { epoch := S m.epoch, password := "", busy := True, notice := "Signing in..." } m in
          (next, Auth.login client m.username m.password (Finished next.epoch . SignedIn))
      Register =>
        let next = { epoch := S m.epoch, password := "", busy := True, notice := "Creating account..." } m in
          (next, Auth.register client m.username m.password (Finished next.epoch . Registered))
      _ => (m, none)

row : Bool -> TodoView -> Widget Msg
row busy todo = WVStack (styled [sTitle ("Todo " ++ todo.id), sBorder RoundedBorder, sPad 12])
  ([text todo.title, text ("ID: " ++ todo.id), text (if todo.done then "Complete" else "Incomplete")] ++
   if busy then [] else
     [WHStack defaultStyle [WCheckbox (styled [sTitle ("Complete " ++ todo.title)]) todo.done (Toggle todo.id),
       button ("Edit " ++ todo.title) (Edit todo.id), button ("Delete " ++ todo.title) (AskDelete todo.id)]])

privateView : Model -> List (Widget Msg)
privateView m =
   (if m.suspended then [text "Paused."] else if m.busy then [text "Working..."] else if isJust m.confirmDelete then [] else
     [WInput (styled [sTitle (case m.editing of Nothing => "New todo title"; Just _ => "Edit todo title")]) m.draft Draft] ++
     (case m.editing of Nothing => [button "Add todo" Add]; Just _ => [button "Save todo" Save, button "Cancel edit" Cancel]) ++
     [button "Refresh" Refresh]) ++
   (case m.confirmDelete of
      Nothing => []
      Just tid => [text "Delete this todo?"] ++ if m.busy || m.suspended then [] else
                    [button "Confirm delete" (Delete tid), button "Keep todo" Keep]) ++
   (if m.loaded && null m.todos then [text "No todos yet."] else []) ++
   map (row (m.busy || m.suspended || isJust m.editing || isJust m.confirmDelete)) m.todos ++
   (case m.nextId of Just _ => if m.busy || m.suspended then [] else [button "Load more" More]; Nothing => [])

public export
view : Model -> Widget Msg
view m = WVStack (styled [sPad 16])
  ([WText (styled [sBold]) "Flux Todo", wrappedText m.notice] ++
   case m.session of
    Just session => [text ("Signed in as " ++ session.account.username), button "Sign out" SignOut] ++ privateView m
    Nothing => case m.pendingLogout of
      Just _ => if m.busy || m.suspended then [text "Working..."] else [button "Retry sign out" RetrySignOut]
      Nothing => if m.busy || m.suspended then [text "Working..."] else
        [wrappedText "Private tasks. Sign in, or create an account with a 15–256 character password. Reloading requires sign-in again.",
         WInput (styled [sTitle "Username"]) m.username Username,
         WInput (styled [sTitle "Password", sSecret]) m.password Password,
         button "Sign in" SignIn, button "Create account" Register])

public export
todoApp : Client -> UIApp Model Msg
todoApp client = MkApp (emptyModel 0 "Sign in to your tasks.", none)
  (update client) view (\_, event => case event of
    LifecycleEvt PageHidden => Just Interrupted
    LifecycleEvt AppPaused => Just Interrupted
    LifecycleEvt PageVisible => Just Resumed
    LifecycleEvt AppResumed => Just Resumed
    _ => Nothing) Nothing
