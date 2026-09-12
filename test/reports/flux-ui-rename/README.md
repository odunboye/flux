# Flux UI breaking rename verification

Verified locally on **macOS / ARM64**, using the pinned pack compiler
(Idris2 0.8.0, `74b33730b6fea649b15e8d01ab099df9effcc7a0`) and Node 26.8.1.
These are not hosted Linux CI results. The root workflow provisions Node 20;
its renamed `flux-ui-browser` check and branch-protection update still need
hosted confirmation. Native iOS/Android SDK certification was not rerun.

## Result

- Canonical `flux-ui` 0.3.0 package; 51 real `Flux.UI` entry/implementation
  modules, no `iris` package, `Iris.*` source tree or legacy wrapper generator.
- `UIApp` and `UIColor` are actual definitions. A new public-API test uses
  `import Flux.UI` and qualified types/constructors on native and Node targets.
- Updated consumers, examples, C symbols/libraries, DOM/CSS/JS hooks, environment
  overrides, CLI, website and active guides. Internal event frames use `f1`;
  tests explicitly reject old `i1` frames. JSON RPC schemas/version are unchanged.
- Source checks cover module/manifest agreement, actual type ownership and the
  absence of legacy runtime identifiers. Browser/server boundaries still pass.

## Evidence

- `workspace/results.json`: **22/22 integration steps passed**, including the
  actual landing server/Chromium checks, generated native/Node/browser clients,
  real PostgreSQL migrations and CRUD, and fresh-copy application creation,
  build, migration, browser use, interruption/persistence and DB isolation.
- `ui-suite.log`: **seven native Idris suites**, public API on Node, all todo
  example builds (including the separate web entry), two real pseudo-terminal
  startup/render/C-FFI/keyboard-shutdown checks, release asset validation, and
  **three real Chromium tests** passed.
- `python.log`: **23 tool tests** passed; `generator.log`: **18 generator tests**.
- ShellCheck, actionlint 1.7.7 and `git diff --check` passed locally.
- `provenance.log`: all six original subtree tips remain ancestors; import
  records are unchanged. Older reports/changelog entries and original sibling
  repositories were not renamed or rewritten.

Browser testing caught the DOM dispatcher's single-character event-prefix
filter; it now recognizes the renamed `f1` frames. Public-entry compilation
also caught a missing public event import, which is now included. The native
smoke harness drains PTY output while waiting for shutdown, avoiding output
backpressure without increasing its 15-second startup / 10-second quit limits.

## Reproduce

```sh
python3 tools/workspace.py check
python3 tools/workspace.py test
(cd packages/ui && npm ci && npx playwright install chromium)
CI=1 bash tools/ci-suite.sh ui
```

See [the breaking migration guide](../../../packages/ui/MIGRATION.md). No
compatibility aliases or automatic old-bundle translation are provided.
