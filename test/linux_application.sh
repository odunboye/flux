#!/bin/sh
# Run inside the idris2-pack Linux image with this workspace mounted read-only
# at /workspace. Requires python3, libssl-dev, and access to a disposable PG DB.
# PG_TEST_* select the database; never point this at application data.
set -eu
python3 - <<'PY'
from pathlib import Path
import shutil
root = Path('/tmp/flux-application')
projects = ['projects/flux', 'playground/todo-api', 'libs/idris2-flux-async',
            'libs/idris2-elin', 'libs/idris2-pg', 'libs/idris2-docker',
            'libs/nebula', 'libs/nebula-flux']
for project in projects:
    dest = root / project
    shutil.copytree(Path('/workspace') / project, dest,
                    ignore=shutil.ignore_patterns('.git', 'build', 'lib', '__pycache__'),
                    dirs_exist_ok=True)
    for config in dest.rglob('pack.toml'):
        config.write_text(config.read_text().replace('/Users/odunadeboye/dev/idris2', str(root)))
config = root / 'playground/todo-api/pack.toml'
with config.open('a') as out:
    out.write('\n[custom.all.elin]\ntype = "local"\npath = "../../libs/idris2-elin"\nipkg = "elin.ipkg"\n')
PY
cd /tmp/flux-application/playground/todo-api
pack --no-prompt build todo-api.ipkg
pack --no-prompt build test/pooled-test.ipkg
TODO_API_SKIP_DOCKER=1 python3 test/runtime_integration_test.py --pooled
for owners in 1 2 4; do
  TODO_API_SKIP_DOCKER=1 python3 test/runtime_http_test.py --owners "$owners"
done
