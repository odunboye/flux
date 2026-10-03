#!/bin/sh
# Mount the Flux repository (not its former parent workspace) at /workspace:ro.
# Requires pack, python3, and access to a disposable PostgreSQL database.
# PG_TEST_* select the test DB; never point this at application data.
set -eu
python3 - <<'PY'
from pathlib import Path
import shutil
shutil.copytree('/workspace', '/tmp/flux-application',
                ignore=shutil.ignore_patterns('.git', 'build', 'lib', 'node_modules', '__pycache__'),
                dirs_exist_ok=True)
PY
cd /tmp/flux-application/apps/todo-api
pack --no-prompt build todo-api.ipkg
pack --no-prompt build test/pooled-test.ipkg
TODO_API_SKIP_DOCKER=1 python3 test/runtime_integration_test.py --pooled
for owners in 1 2 4; do
  TODO_API_SKIP_DOCKER=1 python3 test/runtime_http_test.py --owners "$owners"
done
