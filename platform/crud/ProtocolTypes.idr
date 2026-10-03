-- Generated protocol SHA-256: ab2611d80c30ca34eb8152fabb68a651adcd6a7f06cbb795cc2ce8bbf3f8dc81. Do not edit.
module ProtocolTypes

import public JSON.Simple

%default covering

public export
record CreateTodoRequest where
  constructor MkCreateTodoRequest
  title : String

export
ToJSON CreateTodoRequest where
  toJSON v = JObject [("title", toJSON v.title)]

export
FromJSON CreateTodoRequest where
  fromJSON = withObject "CreateTodoRequest" $ \obj =>
    MkCreateTodoRequest <$> field obj "title"

public export
record DeleteTodoResponse where
  constructor MkDeleteTodoResponse
  deleted : Bool

export
ToJSON DeleteTodoResponse where
  toJSON v = JObject [("deleted", toJSON v.deleted)]

export
FromJSON DeleteTodoResponse where
  fromJSON = withObject "DeleteTodoResponse" $ \obj =>
    MkDeleteTodoResponse <$> field obj "deleted"

public export
record TodoView where
  constructor MkTodoView
  done : Bool
  id : String
  title : String

export
ToJSON TodoView where
  toJSON v = JObject [("done", toJSON v.done), ("id", toJSON v.id), ("title", toJSON v.title)]

export
FromJSON TodoView where
  fromJSON = withObject "TodoView" $ \obj =>
    MkTodoView <$> field obj "done" <*> field obj "id" <*> field obj "title"

public export
record FindTodoResponse where
  constructor MkFindTodoResponse
  todo : Maybe (TodoView)

export
ToJSON FindTodoResponse where
  toJSON v = JObject [("todo", toJSON v.todo)]

export
FromJSON FindTodoResponse where
  fromJSON = withObject "FindTodoResponse" $ \obj =>
    MkFindTodoResponse <$> field obj "todo"

public export
record ListTodosRequest where
  constructor MkListTodosRequest
  afterId : Maybe (String)

export
ToJSON ListTodosRequest where
  toJSON v = JObject [("afterId", toJSON v.afterId)]

export
FromJSON ListTodosRequest where
  fromJSON = withObject "ListTodosRequest" $ \obj =>
    MkListTodosRequest <$> field obj "afterId"

public export
record ListTodosResponse where
  constructor MkListTodosResponse
  nextId : Maybe (String)
  todos : List (TodoView)

export
ToJSON ListTodosResponse where
  toJSON v = JObject [("nextId", toJSON v.nextId), ("todos", toJSON v.todos)]

export
FromJSON ListTodosResponse where
  fromJSON = withObject "ListTodosResponse" $ \obj =>
    MkListTodosResponse <$> field obj "nextId" <*> field obj "todos"

public export
record TodoIdRequest where
  constructor MkTodoIdRequest
  id : String

export
ToJSON TodoIdRequest where
  toJSON v = JObject [("id", toJSON v.id)]

export
FromJSON TodoIdRequest where
  fromJSON = withObject "TodoIdRequest" $ \obj =>
    MkTodoIdRequest <$> field obj "id"

public export
record UpdateTodoRequest where
  constructor MkUpdateTodoRequest
  done : Bool
  id : String
  title : String

export
ToJSON UpdateTodoRequest where
  toJSON v = JObject [("done", toJSON v.done), ("id", toJSON v.id), ("title", toJSON v.title)]

export
FromJSON UpdateTodoRequest where
  fromJSON = withObject "UpdateTodoRequest" $ \obj =>
    MkUpdateTodoRequest <$> field obj "done" <*> field obj "id" <*> field obj "title"
