#!/bin/sh
set -eu
runtime=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
pg="$runtime/../postgres"
cc -O1 -g -Wall -Wextra -Werror -std=c11 -pthread -fsanitize=address,undefined -I"$runtime/c" "$runtime/c/flux_native.c" "$runtime/test/native_test.c" -o /tmp/flux-native-test
/tmp/flux-native-test
cc -O1 -g -Wall -Wextra -Werror -std=c11 -pthread -fsanitize=address,undefined -I"$runtime/c" "$runtime/c/flux_native.c" "$runtime/test/native_stress_test.c" -o /tmp/flux-native-stress
/tmp/flux-native-stress
cc -O1 -g -Wall -Wextra -Werror -std=c11 -pthread -fsanitize=address,undefined -I"$runtime/c" "$runtime/c/flux_native.c" "$runtime/test/watchdog_test.c" -o /tmp/flux-watchdog-test
/tmp/flux-watchdog-test
cc -O1 -g -Wall -Wextra -Werror -std=c11 -fsanitize=address,undefined "$pg/c/pg_transport.c" "$pg/test/native_deadline_test.c" -o /tmp/pg-native-test
/tmp/pg-native-test
