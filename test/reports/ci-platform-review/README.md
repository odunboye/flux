# Consolidation review: CI and dependency boundaries

Both review gaps are addressed without another structural reorganization.

## Verification performed locally (macOS arm64)

- Ten workspace unit tests pass, including twelve direct/transitive boundary
  subcases covering unqualified, compact, equality, range and multiline bounds.
  Parser checks also cover comments, comma continuation, empty declarations,
  property termination, unsupported name syntax and duplicate declarations.
- `bash tools/ci-suite.sh ui`: native Iris unit checks, web/hybrid-mobile bundle
  generation, release-asset validation and all three Chromium tests pass.
- `bash tools/ci-suite.sh platform`: Flux bootstrap build and all sixteen combined
  gate steps pass. This includes eighteen generator tests, generated-output
  freshness, native/JS clients, browser wire tests, PostgreSQL/migrations and
  complete CRUD with independent persistence verification. No database skip.
- ShellCheck, actionlint 1.7.7 and npm's high-severity audit pass (zero reported
  vulnerabilities).

`results.json` and the individual logs are from the latest complete platform
rerun. `ui-lane.log` records the full UI run. `boundary-final.log` additionally
records the final parser checks after adding the empty-declaration assertion.
The compiler was selected via pack rather than the unrelated system Idris.

## CI wiring and remaining external confirmation

The root workflow now has independent `iris-ui-browser` and `generated-client-db`
checks, with `fail-fast: false`, bounded job execution and always-uploaded logs
and browser failure traces. The inert nested UI workflow was removed.

The Linux launcher provisions Node/browser dependencies in the pack container
and uses the hosted runner's Docker socket plus host networking so disposable
PostgreSQL containers' loopback ports are reachable. It has been statically
checked, **not executed on a GitHub-hosted Linux runner in this session**; the
first remote CI run remains necessary to confirm that provisioning environment.
These local results are not presented as a completed GitHub CI run.

Branch protection must require the new checks through repository settings.
No push, product UI/CLI implementation, TLS/authentication change or test-deadline
relaxation is included in this verification patch.
