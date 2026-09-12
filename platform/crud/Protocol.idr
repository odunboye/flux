-- Generated protocol SHA-256: 6fcbf3172431a712be6c13fc580e5c2879b1d128cf1a8286a3ca63ee6a4eabab. Do not edit.
module Protocol

import public ProtocolTypes
import public Flux.Platform.Endpoint
import public Flux.Core.Router

%default covering

public export
record Api where
  constructor MkApi
  createTodo : CreateTodoRequest -> AppProg TodoView
  deleteTodo : TodoIdRequest -> AppProg DeleteTodoResponse
  getTodo : TodoIdRequest -> AppProg FindTodoResponse
  listTodos : ListTodosRequest -> AppProg ListTodosResponse
  toggleTodo : TodoIdRequest -> AppProg FindTodoResponse
  updateTodo : UpdateTodoRequest -> AppProg FindTodoResponse

-- Applications choose CORS policy; this supplies the preflight status.
preflight : Handler
preflight ctx = pure (setStatus 204 ctx)

export
routes : Api -> Router Handler
routes api = empty
  |> post "/rpc/v1/todos/create" (rpcHandler api.createTodo)
  |> options_ "/rpc/v1/todos/create" preflight
  |> post "/rpc/v1/todos/delete" (rpcHandler api.deleteTodo)
  |> options_ "/rpc/v1/todos/delete" preflight
  |> post "/rpc/v1/todos/get" (rpcHandler api.getTodo)
  |> options_ "/rpc/v1/todos/get" preflight
  |> post "/rpc/v1/todos/list" (rpcHandler api.listTodos)
  |> options_ "/rpc/v1/todos/list" preflight
  |> post "/rpc/v1/todos/toggle" (rpcHandler api.toggleTodo)
  |> options_ "/rpc/v1/todos/toggle" preflight
  |> post "/rpc/v1/todos/update" (rpcHandler api.updateTodo)
  |> options_ "/rpc/v1/todos/update" preflight
