#!/usr/bin/env bash
# Tests only; tools/ci-linux.sh provisions the Linux CI environment.
#
# The "ui" suite (Flux UI's own browser/native tests) moved with packages/ui
# to its own repo, https://github.com/odunboye/iris, when it was extracted -
# it had no Flux-specific dependencies. Run its suite from that repo now.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
suite=${1:?usage: ci-suite.sh platform}
case "$suite" in platform) ;; *) echo "Unknown suite: $suite" >&2; exit 2;; esac
reports="$root/.workspace/ci"
mkdir -p "$reports"
trap 'printf "%s\n" "$?" > "$reports/$suite.exit"' EXIT
exec > >(tee "$reports/$suite.log") 2>&1

case "$suite" in
  platform)
    # Bootstrap the pinned compiler before the workspace runner's per-step
    # deadlines; fresh CI images may carry a different pack collection.
    pack --no-prompt build flux.ipkg
    # No --without-db: generated clients, migrations and CRUD must all run.
    python3 tools/workspace.py test
    ;;
esac
