-- Generated protocol SHA-256: 09bdc9856a7cdb35aa7de0a2054917e3be109a17f7760dfbf16df22f56913576. Do not edit.
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
record TodoResponse where
  constructor MkTodoResponse
  done : Bool
  id : String
  title : String

export
ToJSON TodoResponse where
  toJSON v = JObject [("done", toJSON v.done), ("id", toJSON v.id), ("title", toJSON v.title)]

export
FromJSON TodoResponse where
  fromJSON = withObject "TodoResponse" $ \obj =>
    MkTodoResponse <$> field obj "done" <*> field obj "id" <*> field obj "title"

