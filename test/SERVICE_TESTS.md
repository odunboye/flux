# Owner-thread service regression tests

From the package root:

```sh
pack build test/service.ipkg
./test/build/exec/flux-async-service-test
```

The executable exits nonzero on an assertion failure. Run it with an external
process deadline in CI: the test's own polling deadlines cannot interrupt an
arbitrary hung native operation or a stalled main thread.

The suite covers:

- Rejection of zero event loops.
- Root distribution across two distinct OS threads.
- Owner affinity across suspension and child spawning.
- Blocking work running off-loop and resuming on the original owner.
- Cancellation waiting for active blocking work before resource release.
- Children spawned during bracket acquisition stopping before release.
- Shutdown of owner threads and blocking workers, and rejection of later work.
- Drain preserving admitted work and escalation canceling stragglers.
- Pre-start cancellation running a transferred resource's cleanup.

The acquisition-child test reproduced a failure in the bootstrap runner:
`Bracket` ran `acquire` in the outer task's scope, then created a new scope only
for `use`. A watcher spawned by `acquire` therefore outlived the bracket's release.
The fix gives acquisition and use the same scope, closes its children and
blocking jobs, and only then invokes release. Failed acquisition also closes
that scope without attempting to release an unacquired resource.

The service uses the native poller. Socket, stream, PG pool, live HTTP, and
sustained-load checks have separate executables; see the package README and
Flux's `design/RUNTIME_IMPLEMENTATION.md` for the combined verification record.
