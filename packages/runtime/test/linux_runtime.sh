#!/bin/sh
# Mount the workspace at /workspace and quantifiers-extra source at /quantifiers.
# Builds only from source, in the container, without network access.
set -eu
mkdir -p /tmp/flux-linux/quantifiers /tmp/flux-linux/elin /tmp/flux-linux/runtime/test
cp -R /quantifiers/src /quantifiers/quantifiers-extra.ipkg /tmp/flux-linux/quantifiers/
cd /tmp/flux-linux/quantifiers
idris2 --install quantifiers-extra.ipkg
cp -R /workspace/libs/idris2-elin/src /workspace/libs/idris2-elin/elin.ipkg /tmp/flux-linux/elin/
cd /tmp/flux-linux/elin
idris2 --install elin.ipkg
runtime=/workspace/libs/idris2-flux-async
cp -R "$runtime/src" "$runtime/c" "$runtime/Makefile" /tmp/flux-linux/runtime/
cp "$runtime"/test/*.ipkg /tmp/flux-linux/runtime/test/
cp "$runtime/test/socket_test.py" /tmp/flux-linux/runtime/test/
cd /tmp/flux-linux/runtime
for suite in test service stream socket; do
  idris2 --build "test/$suite.ipkg"
done
./test/build/exec/flux-async-test
./test/build/exec/flux-async-service-test
./test/build/exec/flux-async-stream-test
python3 test/socket_test.py
