-- Generated protocol SHA-256: 09bdc9856a7cdb35aa7de0a2054917e3be109a17f7760dfbf16df22f56913576. Do not edit.
module Client

import public ProtocolTypes
import public Flux.Platform.Client

%default covering

export
createTodo : {msg : Type} -> Client -> CreateTodoRequest -> (Either RpcError TodoResponse -> msg) -> Cmd msg
createTodo client input = call client "/rpc/v1/todos/create" input

