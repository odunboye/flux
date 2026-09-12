#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
bin=$(mktemp /tmp/flux-auth-native.XXXXXX)
trap 'rm -f "$bin"' EXIT
pkg-config --atleast-version=1.0.18 libsodium
# pkg-config emits compiler arguments, intentionally split into an array.
read -r -a flags <<< "$(pkg-config --cflags --libs libsodium)"
cc -O1 -g -Wall -Wextra -Werror -std=c11 -fsanitize=address,undefined \
  "$root/c/auth_crypto.c" "$root/test/native_crypto_test.c" "${flags[@]}" -pthread -o "$bin"
"$bin"
