# Flux UI 0.3: breaking rename

This is an **outright rename** of Iris, not an alias package or compatibility
namespace. The implementation lives under `src/Flux/UI/`. There is no `iris`
package, `Iris.*` implementation tree, legacy re-export shim or old-name fallback.

## Application source and packages

| Before | Now |
| --- | --- |
| `depends = iris` | `depends = flux-ui` |
| `iris.ipkg` | `flux-ui.ipkg` |
| `import Iris.…` | `import Flux.UI.…` |
| `IrisApp` | `UIApp` |
| `IrisColor` | `UIColor` |
| `iris-demo` | `flux-ui-demo` |
| `iris-todo*` example packages/binaries | `flux-ui-todo*` |

Qualified names change too: for example `Flux.UI.State.TEA.Cmd` and
`Flux.UI.App.UIApp` are the actual defining namespaces/types, not facades over
old definitions. `import Flux.UI` provides a small application/widget/command
entry point; specialized runners remain in their backend modules.

From the Flux root, install `flux-ui` natively before JS client builds:

```sh
pack --no-prompt install flux-ui
./flux build
```

Update previously generated application projects' package dependencies, imports,
UI type names and host HTML as well; regeneration of RPC files alone cannot
rewrite your handwritten application code.

## Browser and native boundaries

- Host IDs/classes/custom properties use `flux-ui-*`, including `flux-ui-app`
  and `flux-ui-canvas`. Event/style attributes are `data-flux-ui-*`.
- Internal browser globals use `__fluxUI*`. Dataset access uses JavaScript's
  corresponding `fluxUi*` casing (for example `dataset.fluxUiInput`).
- Internal backend event payloads now use **`f1`**, not `i1`. Old versions are
  rejected; migrate/discard any persisted internal events. This does **not**
  change the JSON RPC endpoint version `/rpc/v1/` or application wire schemas.
- Native TUI symbols use `flux_ui_tui_*`, in `c/fluxuitui.c` and `libfluxuitui`.
  Rebuild and ship the new native support library alongside its matching bundle.
- Tooling overrides are `FLUX_UI_ROOT` and `FLUX_UI_MAX_BUNDLE_BYTES`.
- Browser-test npm packages and example filenames are renamed. The hybrid todo
  example's application identifier is now `dev.fluxui.todo`; regenerate native
  example projects and revalidate signing/device installation as needed.

Deploy matching HTML, JS, CSS and native artifacts together. Do not mix old and
new assets, globals or event producers. Remove your own stale build outputs
before rebuilding; this repository does not delete unrelated system-installed
packages or rewrite the original companion repository.

## CI and history

The root UI job is now **`flux-ui-browser`**. Update branch protection from the
old `iris-ui-browser` name when enabling required checks. The generated-client/
database job keeps its existing name and exercises renamed consumers.

Git import provenance, license attribution, historical changelog entries and
saved pre-rename verification reports retain their original names. They are
history, not a supported compatibility surface. Current sources, packages,
examples, scripts, tests, website and guides use Flux UI.

The API/backend maturity limits are unchanged. This rename does not establish
native mobile certification, production authentication or authenticated PG TLS.
