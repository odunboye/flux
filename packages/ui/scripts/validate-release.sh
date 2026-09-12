#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TODO="$ROOT/examples/todo"
WEB_BUNDLE="$TODO/build/exec/iris-todo-web"
MOBILE_BUNDLE="$TODO/mobile/www/app.js"
CONFIG="$TODO/mobile/capacitor.config.json"

fail() { printf 'release validation failed: %s\n' "$*" >&2; exit 1; }

[[ -s "$WEB_BUNDLE" ]] || fail "missing or empty web bundle"
[[ -s "$MOBILE_BUNDLE" ]] || fail "missing or empty mobile bundle"
[[ -s "$TODO/mobile/www/index.html" ]] || fail "missing mobile index.html"
[[ -s "$CONFIG" ]] || fail "missing Capacitor configuration"

node --check "$WEB_BUNDLE"
node --check "$MOBILE_BUNDLE"
node - "$CONFIG" <<'NODE'
const fs = require('fs');
const config = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
for (const key of ['appId', 'appName', 'webDir']) {
  if (!config[key] || typeof config[key] !== 'string') throw new Error(`invalid ${key}`);
}
if (config.webDir !== 'www') throw new Error('Capacitor webDir must be www');
NODE

grep -q 'iris-canvas' "$TODO/mobile/www/index.html" || fail "mobile shell has no iris-canvas"
grep -q '__mainExpression' "$WEB_BUNDLE" || fail "web entrypoint is absent"
grep -q '__mainExpression' "$MOBILE_BUNDLE" || fail "mobile entrypoint is absent"

MAX_BYTES=${IRIS_MAX_BUNDLE_BYTES:-5000000}
for bundle in "$WEB_BUNDLE" "$MOBILE_BUNDLE"; do
  size=$(wc -c < "$bundle" | tr -d ' ')
  (( size <= MAX_BYTES )) || fail "$(basename "$bundle") is $size bytes (limit $MAX_BYTES)"
done

tracked=$(git -C "$ROOT" ls-files | grep -E '(^|/)(build|node_modules)/|mobile/(www/)?app\.js$' || true)
[[ -z "$tracked" ]] || fail "generated artifacts are tracked: $tracked"

printf 'Release assets validated (bundle limit: %s bytes)\n' "$MAX_BYTES"
