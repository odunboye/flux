-- Generated protocol SHA-256: 84e79e50e654d4864c214c9cf335828ab6f308f82fe6eb476b6e975696866226. Do not edit.
module ProtocolTypes

import public JSON.Simple

%default covering

public export
record ProbeRequest where
  constructor MkProbeRequest
  claimedOwner : String

export
ToJSON ProbeRequest where
  toJSON v = JObject [("claimedOwner", toJSON v.claimedOwner)]

export
FromJSON ProbeRequest where
  fromJSON = withObject "ProbeRequest" $ \obj =>
    MkProbeRequest <$> field obj "claimedOwner"

public export
record ProbeResponse where
  constructor MkProbeResponse
  resolvedOwner : String

export
ToJSON ProbeResponse where
  toJSON v = JObject [("resolvedOwner", toJSON v.resolvedOwner)]

export
FromJSON ProbeResponse where
  fromJSON = withObject "ProbeResponse" $ \obj =>
    MkProbeResponse <$> field obj "resolvedOwner"
