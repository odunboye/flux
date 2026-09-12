#!/bin/sh
# Run from a writable Flux monorepo checkout with pack and python3 installed.
set -eu
cd "$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
for suite in test service stream socket; do
  pack --no-prompt build "test/$suite.ipkg"
done
./test/build/exec/flux-runtime-test
./test/build/exec/flux-runtime-service-test
./test/build/exec/flux-runtime-stream-test
python3 test/socket_test.py
