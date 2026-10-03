-- Generated protocol SHA-256: 09bdc9856a7cdb35aa7de0a2054917e3be109a17f7760dfbf16df22f56913576. Do not edit.
module Protocol

import public ProtocolTypes
import public Flux.Platform.Endpoint
import public Flux.Core.Router

%default covering

public export
record Api where
  constructor MkApi
  createTodo : CreateTodoRequest -> AppProg TodoResponse

-- Applications choose CORS policy; this supplies the preflight status.
preflight : Handler
preflight ctx = pure (setStatus 204 ctx)

export
routes : Api -> Router Handler
routes api = empty
  |> post "/rpc/v1/todos/create" (rpcHandler api.createTodo)
  |> options_ "/rpc/v1/todos/create" preflight
