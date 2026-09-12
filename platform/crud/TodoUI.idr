module TodoUI

import Client
import Flux.UI.App
import Flux.UI.Widget
import Flux.UI.Platform.Event
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

public export
data Msg = Draft String | Add | Refresh | More | Edit String | Save | Cancel | Interrupted | Resumed
         | Toggle String | AskDelete String | Keep | Delete String
         | Listed Bool (Either RpcError ListTodosResponse)
         | Created (Either RpcError TodoView)
         | Found (Either RpcError FindTodoResponse)
         | Changed (Either RpcError FindTodoResponse)
         | Deleted String (Either RpcError DeleteTodoResponse)

errorText : RpcError -> String
errorText (RemoteError status code message) = "Request rejected (" ++ show status ++ ", " ++ code ++ "): " ++ message
errorText (InvalidResponse _) = "Invalid server response. Refresh before retrying a write."
errorText (TransportFailure _) = "Connection failed. Refresh before retrying a write."

failed : Model -> RpcError -> (Model, Cmd Msg)
failed m err = ({ busy := False, notice := errorText err } m, none)

-- IDs remain decimal strings. De-duplicate when a newly created row is also
-- returned by a subsequent keyset page; never convert BIGINTs to JS numbers.
merge : List TodoView -> List TodoView -> List TodoView
merge old incoming = filter (\t => not (any (\n => n.id == t.id) incoming)) old ++ incoming

validTitle : String -> Bool
validTitle value = value /= "" && length (unpack value) <= 128

act : Client -> Msg -> Model -> (Model, Cmd Msg)
act client (Draft value) m = ({ draft := value } m, none)
act client Refresh m = ({ busy := True, notice := "Refreshing..." } m, listTodos client (MkListTodosRequest Nothing) (Listed False))
act client More m = case m.nextId of
  Nothing => (m, none)
  Just cursor => ({ busy := True, notice := "Loading more..." } m, listTodos client (MkListTodosRequest (Just cursor)) (Listed True))
act client Add m =
  if validTitle m.draft
    then ({ busy := True, notice := "Creating..." } m, createTodo client (MkCreateTodoRequest m.draft) Created)
    else ({ notice := "Title must contain 1 to 128 characters." } m, none)
act client (Edit tid) m = ({ busy := True, notice := "Loading todo..." } m, getTodo client (MkTodoIdRequest tid) Found)
act client Save m = case m.editing of
  Nothing => (m, none)
  Just todo => if validTitle m.draft
    then ({ busy := True, notice := "Saving..." } m, updateTodo client (MkUpdateTodoRequest todo.done todo.id m.draft) Changed)
    else ({ notice := "Title must contain 1 to 128 characters." } m, none)
act client Cancel m = ({ editing := Nothing, draft := "", notice := "Edit cancelled." } m, none)
act client (Toggle tid) m = ({ busy := True, notice := "Updating..." } m, toggleTodo client (MkTodoIdRequest tid) Changed)
act client (AskDelete tid) m = ({ confirmDelete := Just tid } m, none)
act client Keep m = ({ confirmDelete := Nothing } m, none)
act client (Delete tid) m = case m.confirmDelete of
  Just confirmed => if confirmed == tid
    then ({ busy := True, notice := "Deleting..." } m, deleteTodo client (MkTodoIdRequest tid) (Deleted tid))
    else (m, none)
  Nothing => (m, none)
act _ _ m = (m, none)

public export
update : Client -> Msg -> Model -> (Model, Cmd Msg)
update _ Interrupted m =
  ({ busy := False, suspended := True,
     notice := if m.busy then "Request interrupted. Refresh before retrying a write." else m.notice } m, none)
update _ Resumed m = ({ suspended := False } m, none)
update _ (Listed append (Left err)) m = failed m err
update _ (Listed append (Right page)) m =
  ({ todos := if append then merge m.todos page.todos else page.todos,
     nextId := page.nextId, busy := False, loaded := True, notice := "Ready." } m, none)
update _ (Created (Left err)) m = failed m err
update _ (Created (Right todo)) m =
  ({ todos := merge m.todos [todo], draft := "", busy := False, notice := "Created." } m, none)
update _ (Found (Left err)) m = failed m err
update _ (Found (Right result)) m = case result.todo of
  Nothing => ({ busy := False, notice := "Todo no longer exists. Refresh the list." } m, none)
  Just todo => ({ editing := Just todo, draft := todo.title, busy := False, notice := "Editing." } m, none)
update _ (Changed (Left err)) m = failed m err
update _ (Changed (Right result)) m = case result.todo of
  Nothing => ({ busy := False, notice := "Todo no longer exists. Refresh the list." } m, none)
  Just todo => ({ todos := merge m.todos [todo], editing := Nothing,
     draft := case m.editing of Nothing => m.draft; Just _ => "", busy := False, notice := "Saved." } m, none)
update _ (Deleted tid (Left err)) m = failed m err
update _ (Deleted tid (Right result)) m =
  ({ todos := filter (\t => t.id /= tid) m.todos, confirmDelete := Nothing,
     busy := False, notice := if result.deleted then "Deleted." else "Already deleted." } m, none)
update client msg m = if m.busy || m.suspended then (m, none) else act client msg m

row : Bool -> TodoView -> Widget Msg
row busy todo = WVStack (styled [sTitle ("Todo " ++ todo.id), sBorder RoundedBorder, sPad 12])
  ([text todo.title, text ("ID: " ++ todo.id), text (if todo.done then "Complete" else "Incomplete")] ++
   if busy then [] else
     [WHStack defaultStyle [WCheckbox (styled [sTitle ("Complete " ++ todo.title)]) todo.done (Toggle todo.id),
       button ("Edit " ++ todo.title) (Edit todo.id), button ("Delete " ++ todo.title) (AskDelete todo.id)]])

public export
view : Model -> Widget Msg
view m = WVStack (styled [sPad 16])
  ([WText (styled [sBold]) "Flux Todo", wrappedText "A Flux UI application using generated Idris RPC commands.",
    wrappedText m.notice] ++
   (if m.suspended then [text "Paused."] else if m.busy then [text "Working..."] else if isJust m.confirmDelete then [] else
     [WInput (styled [sTitle (case m.editing of Nothing => "New todo title"; Just _ => "Edit todo title")]) m.draft Draft] ++
     (case m.editing of
       Nothing => [button "Add todo" Add]
       Just _ => [button "Save todo" Save, button "Cancel edit" Cancel]) ++
     [button "Refresh" Refresh]) ++
   (case m.confirmDelete of
      Nothing => []
      Just tid => [text "Delete this todo?"] ++ if m.busy || m.suspended then [] else
                    [button "Confirm delete" (Delete tid), button "Keep todo" Keep]) ++
   (if m.loaded && null m.todos then [text "No todos yet."] else []) ++
   map (row (m.busy || m.suspended || isJust m.editing || isJust m.confirmDelete)) m.todos ++
   (case m.nextId of
      Just _ => if m.busy || m.suspended then [] else [button "Load more" More]
      Nothing => []))

public export
todoApp : Client -> UIApp Model Msg
todoApp client = MkApp
  (MkModel [] Nothing "" Nothing Nothing True False False "Loading...",
   listTodos client (MkListTodosRequest Nothing) (Listed False))
  (update client) view (\_, event => case event of
    LifecycleEvt PageHidden => Just Interrupted
    LifecycleEvt AppPaused => Just Interrupted
    LifecycleEvt PageVisible => Just Resumed
    LifecycleEvt AppResumed => Just Resumed
    _ => Nothing) Nothing
