-- Generated protocol SHA-256: 6fcbf3172431a712be6c13fc580e5c2879b1d128cf1a8286a3ca63ee6a4eabab. Do not edit.
module Client

import public ProtocolTypes
import public Flux.Platform.Client

%default covering

export
createTodo : {msg : Type} -> Client -> CreateTodoRequest -> (Either RpcError TodoView -> msg) -> Cmd msg
createTodo client input = call client "/rpc/v1/todos/create" input

export
deleteTodo : {msg : Type} -> Client -> TodoIdRequest -> (Either RpcError DeleteTodoResponse -> msg) -> Cmd msg
deleteTodo client input = call client "/rpc/v1/todos/delete" input

export
getTodo : {msg : Type} -> Client -> TodoIdRequest -> (Either RpcError FindTodoResponse -> msg) -> Cmd msg
getTodo client input = call client "/rpc/v1/todos/get" input

export
listTodos : {msg : Type} -> Client -> ListTodosRequest -> (Either RpcError ListTodosResponse -> msg) -> Cmd msg
listTodos client input = call client "/rpc/v1/todos/list" input

export
toggleTodo : {msg : Type} -> Client -> TodoIdRequest -> (Either RpcError FindTodoResponse -> msg) -> Cmd msg
toggleTodo client input = call client "/rpc/v1/todos/toggle" input

export
updateTodo : {msg : Type} -> Client -> UpdateTodoRequest -> (Either RpcError FindTodoResponse -> msg) -> Cmd msg
updateTodo client input = call client "/rpc/v1/todos/update" input
