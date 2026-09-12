-- Generated protocol SHA-256: ab2611d80c30ca34eb8152fabb68a651adcd6a7f06cbb795cc2ce8bbf3f8dc81. Do not edit.
module Protocol

import public ProtocolTypes
import public Flux.Platform.Endpoint
import public Flux.Core.Router

%default covering

public export
record Api where
  constructor MkApi
  createTodo : Principal -> CreateTodoRequest -> AppProg TodoView
  deleteTodo : Principal -> TodoIdRequest -> AppProg DeleteTodoResponse
  getTodo : Principal -> TodoIdRequest -> AppProg FindTodoResponse
  listTodos : Principal -> ListTodosRequest -> AppProg ListTodosResponse
  toggleTodo : Principal -> TodoIdRequest -> AppProg FindTodoResponse
  updateTodo : Principal -> UpdateTodoRequest -> AppProg FindTodoResponse

-- Applications choose CORS policy; this supplies the preflight status.
preflight : Handler
preflight ctx = pure (setStatus 204 ctx)

export
routes : Authenticator -> Api -> Router Handler
routes authenticate api = empty
  |> post "/rpc/v1/todos/create" (rpcAuthenticatedHandler authenticate api.createTodo)
  |> options_ "/rpc/v1/todos/create" preflight
  |> post "/rpc/v1/todos/delete" (rpcAuthenticatedHandler authenticate api.deleteTodo)
  |> options_ "/rpc/v1/todos/delete" preflight
  |> post "/rpc/v1/todos/get" (rpcAuthenticatedHandler authenticate api.getTodo)
  |> options_ "/rpc/v1/todos/get" preflight
  |> post "/rpc/v1/todos/list" (rpcAuthenticatedHandler authenticate api.listTodos)
  |> options_ "/rpc/v1/todos/list" preflight
  |> post "/rpc/v1/todos/toggle" (rpcAuthenticatedHandler authenticate api.toggleTodo)
  |> options_ "/rpc/v1/todos/toggle" preflight
  |> post "/rpc/v1/todos/update" (rpcAuthenticatedHandler authenticate api.updateTodo)
  |> options_ "/rpc/v1/todos/update" preflight
