#!/bin/sh
set -eu
root=/Users/odunadeboye/dev/idris2
out=$root/projects/flux/test/reports/runtime-completion/final
mkdir -p "$out"
cd "$root/libs/idris2-pg"
for suite in unit-test prop-test test tls-deadline; do
 pack --no-prompt build "test/$suite.ipkg" > "$out/macos-pg-$suite-build.log" 2>&1
done
./test/build/exec/idris2-pg-unit-test > "$out/macos-pg-unit.log" 2>&1
! grep -q 'FAIL' "$out/macos-pg-unit.log"
./test/build/exec/idris2-pg-prop-test > "$out/macos-pg-properties.log" 2>&1
! grep -qi 'failed\|FAIL' "$out/macos-pg-properties.log"
PG_TEST_DB=flux_final_pg_test python3 test/runtime_integration_test.py > "$out/macos-pg-integration.log" 2>&1
pack --no-prompt build async/test.ipkg > "$out/macos-pool-build.log" 2>&1
python3 test/pool_test.py > "$out/macos-pool.log" 2>&1
python3 test/tls_deadline_test.py > "$out/macos-tls.log" 2>&1
cd "$root/libs/idris2-flux-async"
make -f test/Makefile.native check > "$out/macos-native.log" 2>&1
for suite in test service stream socket; do
 pack --no-prompt build "test/$suite.ipkg" > "$out/macos-runtime-$suite-build.log" 2>&1
done
./test/build/exec/flux-async-test > "$out/macos-runtime.log" 2>&1
./test/build/exec/flux-async-service-test > "$out/macos-service.log" 2>&1
./test/build/exec/flux-async-stream-test > "$out/macos-stream.log" 2>&1
python3 test/socket_test.py > "$out/macos-socket.log" 2>&1
cd "$root/projects/flux"
pack --no-prompt build test/test.ipkg > "$out/macos-flux-build.log" 2>&1
./test/build/exec/flux-test > "$out/macos-flux.log" 2>&1
pack --no-prompt build examples/examples.ipkg > "$out/macos-examples-build.log" 2>&1
python3 test/runtime_protocol_test.py > "$out/macos-protocol.log" 2>&1
cd "$root/playground/todo-api"
pack --no-prompt build todo-api.ipkg > "$out/macos-todo-build.log" 2>&1
pack --no-prompt build test/pooled-test.ipkg > "$out/macos-todo-pooled-build.log" 2>&1
TODO_API_SKIP_DOCKER=1 python3 test/runtime_integration_test.py --pooled > "$out/macos-todo-pooled.log" 2>&1
for owners in 1 2 4; do
 TODO_API_SKIP_DOCKER=1 python3 test/runtime_http_test.py --owners "$owners" > "$out/macos-todo-$owners.log" 2>&1
done
