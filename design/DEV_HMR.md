# Opt-in DOM hot replacement (Flux UI 0.4)

```sh
./flux dev --hot --disposable-db
# Chequra already provides a model codec:
cd ../chequra
flux build
CHEQURA_PROVIDER=simulated flux dev --hot --no-build --disposable-db --port 8091
```

External projects use the same [installed CLI and declarative configuration](APPLICATION_CLI.md).
`--hot` implies `--watch`. Plain `--watch` retains its full-page reload behaviour.
Only UI-only publications (optionally accompanied by CSS) are eligible for hot
replacement. Server, shared model source, RPC schema, native library, manifest,
HTML/image and development-server session changes still cause a full reload.
CSS-only changes still replace the stylesheet without touching the runtime.

This is actual code replacement without navigating/reloading the page, but not
compiler-inferred migration of arbitrary Idris heap values. It requires an
explicit application wire boundary. The `UIApp` record and normal `runWeb` API
are unchanged. Canvas, terminal and arbitrary application-owned globals are not
hot-replaced by this DOM feature.

## Application API

Declare a direct `flux-ui >= 0.4.0` dependency in the browser ipkg (this also
prevents an older globally installed Flux UI from shadowing the new API):

```idris
import Flux.UI.Backend.Web.DOM.Run

codec : HotState Model
codec = MkHotState "my-model-v1" saveModel restoreModel

-- saveModel : Model -> Maybe String
-- restoreModel : String -> Maybe Model

main : IO ()
main = runWebHot codec myApp
```

- `version` is an application-owned compatibility key. Bump it whenever state
  schema or meaning changes incompatibly. Matching versions alone do not prove
  compatibility; `restore` must decode, validate and sanitize its input.
- `save` returns a serialized string, or `Nothing` to **defer** replacement. Use
  deferral during in-flight writes/authentication/logout or lifecycle suspension.
  The old app remains usable; the client retries after it becomes idle. Do not
  use deferral for permanently incompatible states—change the version or reject
  in `restore` instead. A quit runtime falls back to reload.
- `restore` is a pure, explicit decoding/migration function in the **new bundle**.
  It returns a newly constructed model in that compilation's representation.
  Returning `Nothing` or throwing during preparation falls back to a page reload.
  Never cast a raw object from a previous compiler generation into a new model.
- Successful restore skips `app.init` commands. It must not silently replay
  startup requests or writes. Applications with persistent subscriptions must
  explicitly arrange safe resubscription through application-managed events;
  the framework does not replay old effects or serialize subscriptions.
- Put startup effects inside managed `Cmd`s, not in browser `main` before
  `runWebHot`. Loading a new bundle executes its top-level code; arbitrary global
  side effects cannot be rolled back by this protocol.

Without the development hot bridge, `runWebHot` behaves like `runWeb`: no model
serialization, transport or storage occurs. Applications still using `runWeb`
fall back to full reload even under `--hot`.

## Swap protocol

1. The dev server publishes immutable assets after successful compilation and
   increments a separate UI revision. HTML carries starting CSS/UI/full-reload
   revisions and a development session ID.
2. The development client asks the active runtime for an idle snapshot. Pending
   DOM inputs are drained using the old event maps before saving, so an edit or
   payment click queued just before the swap cannot be silently omitted.
3. A same-origin external script loads the new compiled bundle in an isolated
   IIFE lexical scope. No `eval`, `unsafe-eval`, inline script or persistent model
   cache is needed. The bridge is loaded before application JS, only under hot
   dev. Hot asset requests pin UI revision, full-reload revision and session;
   stale requests cannot receive an unrelated newer bundle.
4. The new `runWebHot` registers a candidate but does not mount it yet. The bridge
   compares compatibility keys, captures the latest idle state, decodes it into
   the new model and preflights the new view. Payloads are limited to 2MiB.
5. In one synchronous browser turn, the old runtime sets its quit flag, cancels
   managed effects, invalidates callbacks, aborts event listeners, clears its
   timer chains and removes its constructed stylesheet/rules. Capacitor listeners
   installed by the DOM runner are also removed, including late registrations.
6. The new runtime mounts with the restored model, rebuilt event maps, fresh
   render/tick loops and styles. Old initialization commands are not replayed.

A failed build never publishes a new bundle. A hot-script transport failure keeps
the old UI and retries. Busy apps defer. Version mismatch, decoder rejection,
missing registration or a preparation/startup exception causes a full reload.
A replacement which removed `runWebHot` is prevented from mounting a second
plain runtime before that fallback. Timed-out scripts cannot later mount over the
active app. Arbitrary side effects in custom initialization or cancellation code
remain the application's responsibility.

DOM replacement preserves input focus/selection using the existing stable input
IDs when the new widget structure keeps those IDs. Reordering widgets can change
those IDs; semantic focus migration is not part of the model codec.

## Security and operations

State strings are held only in in-page closures and are not sent to the dev
server, logged, placed in URLs, localStorage/sessionStorage, cookies or indexedDB.
They can contain an existing bearer **only if the application opts into that**;
this does not mint, renew or bypass server authentication. Same-origin application
scripts and developer tools already have access to in-memory application state.
Do not serialize passwords or verification codes. Clear transient credentials
and bump application request epochs when restoring.

Chequra's `src/UI/Hot.idr` preserves wallets, operations/review IDs, form drafts,
in-memory session and onboarding position. It omits passwords, OTP input and
pending logout credentials; it defers while busy/suspended/logout is pending and
increments the epoch on restore. No login, dashboard request or money operation
is automatically replayed. Full reloads still clear authentication and onboarding.

The existing live-reload [security and backend/migration caveats](DEV_RELOAD.md)
continue to apply. New hot JS has the same privileges as the existing application;
this is trusted local development tooling, not an isolation boundary for hostile
code. A backend can change after a client checks a revision, as with any web app;
server-side principal resolution and write/idempotency protections remain vital.

## Tests

```sh
# Framework tests compile five real Idris bundles, then drive Chromium:
python3 -m unittest discover -s tools -p 'test_hot.py' -v
python3 -m unittest discover -s tools -p 'test_devwatch.py' -v
# Chequra, after flux build; explicitly mocked auth/RPC, no database required:
cd ../chequra
python3 tests/test_hot.py
```

Framework acceptance checks changed update/view implementations, retained model,
busy deferral, network-failure recovery, cancellation, stale callbacks, one timer
pair/stylesheet, no initialization replay, version mismatch, decoder rejection,
and fallback after switching back to plain runWeb. Chequra tests use its real
compiled UI/codec with mocked RPC responses to verify session, wallet, draft and
onboarding preservation plus password/OTP clearing and absence of RPC replay or
browser storage. Database/auth-server integration is a separate acceptance gate.
