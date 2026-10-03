#!/bin/sh
set -eu
out=/tmp/final-regression
mkdir -p "$out"
ln -sfn /root/.cache/pack/git/github.com/stefan-hoeck/idris2-quantifiers-extra /quantifiers
sh /workspace/libs/idris2-flux-async/test/linux_runtime.sh > "$out/runtime.log" 2>&1
ASAN_OPTIONS=detect_leaks=0 sh /workspace/libs/idris2-flux-async/test/linux_native.sh > "$out/native.log" 2>&1
cd /tmp/flux-application/playground/todo-api
# Use the app's complete, Linux-local dependency configuration for PG tests.
pack --no-prompt build ../../libs/idris2-pg/test/unit-test.ipkg > "$out/pg-unit-build.log" 2>&1
../../libs/idris2-pg/test/build/exec/idris2-pg-unit-test > "$out/pg-unit.log" 2>&1
! grep -q FAIL "$out/pg-unit.log"
pack --no-prompt build ../../libs/idris2-pg/test/prop-test.ipkg > "$out/pg-properties-build.log" 2>&1
../../libs/idris2-pg/test/build/exec/idris2-pg-prop-test > "$out/pg-properties.log" 2>&1
! grep -qi 'FAIL' "$out/pg-properties.log"
pack --no-prompt build ../../libs/idris2-pg/test/test.ipkg > "$out/pg-integration-build.log" 2>&1
PG_TEST_DB=flux_final_pg_test python3 ../../libs/idris2-pg/test/runtime_integration_test.py > "$out/pg-integration.log" 2>&1
pack --no-prompt build ../../projects/flux/test/test.ipkg > "$out/flux-build.log" 2>&1
../../projects/flux/test/build/exec/flux-test > "$out/flux.log" 2>&1
pack --no-prompt build ../../projects/flux/examples/examples.ipkg > "$out/examples-build.log" 2>&1
python3 ../../projects/flux/test/runtime_protocol_test.py > "$out/protocol.log" 2>&1
python3 test/runtime_integration_test.py --pooled > "$out/todo-pooled.log" 2>&1
for owners in 1 2 4; do
 python3 test/runtime_http_test.py --owners "$owners" > "$out/todo-$owners.log" 2>&1
done
