# Native poller verification

Run from the package root:

```sh
make -f test/Makefile.native check
```

This compiles the native test executables with warnings as errors,
AddressSanitizer, and UndefinedBehaviorSanitizer. To run without sanitizers:

```sh
make -f test/Makefile.native check NATIVE_SANITIZERS=
```

Coverage:

- Read readiness, EOF, overlapping-direction rejection, and registration tokens.
- Wake pipe saturation and cross-thread wake delivery.
- A 50 ms poll deadline interrupted repeatedly by signals. Interruptions must
  not reset its timeout; the test allows a 500 ms upper bound for scheduling.
- 5,000 registration/read/remove cycles while four threads continuously wake
  the poller. Wake draining must not starve socket readiness.

Verified on macOS arm64 and Linux amd64 during development. These tests do not
establish thread-race freedom or end-to-end runtime correctness.
AddressSanitizer/UndefinedBehaviorSanitizer do not replace ThreadSanitizer.

Integration requirements for the owner-loop implementation:

- Publish a mailbox command before waking its owner.
- Only the owner adds/removes registrations or polls. Only `wake` is callable
  concurrently with those operations.
- Readiness snapshots can contain tokens removed after `wait` returns; the
  Idris registration table must reject inactive tokens before resuming tasks.
- Assign a fresh token on every registration, including descriptor reuse.
- Stop and join wake producers before freeing the poller. Its wake pipe must
  not be closed concurrently with a writer.
- Use the collect-safe FFI for blocking poll calls on Chez.

The shim also supplies nonblocking socket primitives and an explicit
standalone signal watchdog. Task ownership, connection admission, and
resource cleanup remain in the Idris runtime. Native watchdog tests run a
child process and require its forced-exit status to be 124.
