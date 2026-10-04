#!/usr/bin/env bash
# GitHub-hosted Ubuntu launcher. Requires Docker and Node >=20 on the host.
# Explicit host networking lets child PostgreSQL containers' published
# 127.0.0.1 ports reach the Idris tests inside the compiler container.
#
# The "ui" suite (Flux UI's own browser/native tests) moved with packages/ui
# to its own repo, https://github.com/odunboye/iris, when it was extracted -
# it had no Flux-specific dependencies. This repo's own browser tests
# (dev-server hot reload, landing page) still need the shared root-level
# Playwright dependency installed below.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
suite=${1:?usage: ci-linux.sh platform}
case "$suite" in platform) ;; *) echo "Unknown suite: $suite" >&2; exit 2;; esac
[[ $(uname -s) == Linux ]] || { echo 'This CI launcher requires a Linux Docker host' >&2; exit 2; }
node_root=$(node -p 'require("path").dirname(require("path").dirname(require("fs").realpathSync(process.execPath)))')
node -e 'if(Number(process.versions.node.split(".")[0]) < 20) process.exit(1)'
docker pull postgres:16

docker run --rm --init --network host \
  --volume "$root:$root" --workdir "$root" \
  --volume "$node_root:/opt/flux-node:ro" \
  --volume /var/run/docker.sock:/var/run/docker.sock \
  --env CI=1 --env DEBIAN_FRONTEND=noninteractive \
  --entrypoint bash ghcr.io/stefan-hoeck/idris2-pack:latest \
  -ec '
    export PATH="/opt/flux-node/bin:$PATH"
    apt-get update
    apt-get install -y --no-install-recommends python3 curl docker.io build-essential procps libssl-dev libsodium-dev libcurl4-openssl-dev pkg-config
    npm ci
    npm audit --audit-level=high
    npx playwright install --with-deps chromium
    bash tools/ci-suite.sh "$1"
  ' bash "$suite"
