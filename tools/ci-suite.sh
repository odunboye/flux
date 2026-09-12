#!/usr/bin/env bash
# Tests only; tools/ci-linux.sh provisions the Linux CI environment.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
suite=${1:?usage: ci-suite.sh ui|platform}
case "$suite" in ui|platform) ;; *) echo "Unknown suite: $suite" >&2; exit 2;; esac
reports="$root/.workspace/ci"
mkdir -p "$reports"
trap 'printf "%s\n" "$?" > "$reports/$suite.exit"' EXIT
exec > >(tee "$reports/$suite.log") 2>&1

case "$suite" in
  ui)
    # Install the native demo/library before any browser compilation. The
    # Use pack's compiler explicitly: an unrelated system idris2 may have
    # an incompatible TTC format even when it also reports version 0.8.0.
    pack --no-prompt install iris
    compiler=$(pack app-path idris2)
    compiler_dir=$(dirname "$compiler")
    export PATH="$compiler_dir:$PATH"
    IDRIS2_PACKAGE_PATH=$(pack package-path)
    IDRIS2_LIBS=$(pack libs-path)
    export IDRIS2_PACKAGE_PATH IDRIS2_LIBS
    make -C packages/ui check
    make -C packages/ui browser-test
    ;;
  platform)
    # Bootstrap the pinned compiler before the workspace runner's per-step
    # deadlines; fresh CI images may carry a different pack collection.
    pack --no-prompt build flux.ipkg
    # No --without-db: generated clients, migrations and CRUD must all run.
    python3 tools/workspace.py test
    ;;
esac
