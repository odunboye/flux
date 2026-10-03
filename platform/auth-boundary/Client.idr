-- Generated protocol SHA-256: 84e79e50e654d4864c214c9cf335828ab6f308f82fe6eb476b6e975696866226. Do not edit.
module Client

import public ProtocolTypes
import public Flux.Platform.Client

%default covering

export
privateProbe : {msg : Type} -> Client -> ProbeRequest -> (Either RpcError ProbeResponse -> msg) -> Cmd msg
privateProbe client input = call client "/rpc/v1/probe/private" input

export
publicProbe : {msg : Type} -> Client -> ProbeRequest -> (Either RpcError ProbeResponse -> msg) -> Cmd msg
publicProbe client input = call client "/rpc/v1/probe/public" input
