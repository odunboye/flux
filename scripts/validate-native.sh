#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
MOBILE="$ROOT/examples/todo/mobile"
PLATFORM=${1:-all}

cd "$ROOT/examples/todo"
make build-mobile
cd "$MOBILE"
npm ci

sync_ios() {
  command -v xcodebuild >/dev/null || { echo 'skip iOS: Xcode is unavailable'; return; }
  [[ -d ios ]] || npx cap add ios
  npx cap sync ios
  xcodebuild -workspace ios/App/App.xcworkspace -scheme App -sdk iphonesimulator \
    -configuration Debug CODE_SIGNING_ALLOWED=NO build
}

sync_android() {
  [[ -n ${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}} ]] || { echo 'skip Android: SDK is unavailable'; return; }
  [[ -d android ]] || npx cap add android
  npx cap sync android
  if [[ $(uname -s) == Darwin ]] && /usr/libexec/java_home -v 17 >/dev/null 2>&1; then
    export JAVA_HOME=$(/usr/libexec/java_home -v 17)
  fi
  (cd android && ./gradlew assembleDebug)
}

case "$PLATFORM" in
  ios) sync_ios ;;
  android) sync_android ;;
  all) sync_ios; sync_android ;;
  *) echo "usage: $0 [ios|android|all]" >&2; exit 2 ;;
esac
