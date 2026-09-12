CC ?= cc
CFLAGS ?= -O2 -Wall -Wextra -Werror -std=c11 -pthread
UNAME := $(shell uname -s)
ifeq ($(UNAME),Darwin)
SHARED_FLAGS = -dynamiclib
SUFFIX = dylib
else
SHARED_FLAGS = -shared -fPIC
SUFFIX = so
endif

.PHONY: native test-native test clean
native:
	mkdir -p build/native lib
	$(CC) $(CFLAGS) $(SHARED_FLAGS) c/flux_native.c -o build/native/libflux_async.$(SUFFIX)
	cp build/native/libflux_async.$(SUFFIX) lib/

test-libs: native
	mkdir -p test/build/exec/flux-async-stream-test_app
	cp lib/libflux_async.$(SUFFIX) test/build/exec/flux-async-stream-test_app/
	mkdir -p test/build/exec/flux-async-test_app test/build/exec/flux-async-service-test_app test/build/exec/flux-async-socket-test_app
	cp lib/libflux_async.$(SUFFIX) test/build/exec/flux-async-test_app/
	cp lib/libflux_async.$(SUFFIX) test/build/exec/flux-async-service-test_app/
	cp lib/libflux_async.$(SUFFIX) test/build/exec/flux-async-socket-test_app/

test-native:
	mkdir -p build/native
	$(CC) $(CFLAGS) -pthread -Ic c/flux_native.c test/native_test.c -o build/native/native-test
	./build/native/native-test

test: test-native
	pack --no-prompt build test/test.ipkg
	./test/build/exec/flux-async-test
