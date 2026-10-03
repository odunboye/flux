CC ?= cc
CFLAGS ?= -O2 -Wall -Wextra -Werror -std=c11
ifeq ($(shell uname -s),Darwin)
SHARED = -dynamiclib
SUFFIX = dylib
else
SHARED = -shared -fPIC
SUFFIX = so
endif
.PHONY: native-client
native-client:
	pkg-config --atleast-version=7.85.0 libcurl
	mkdir -p lib
	$(CC) $(CFLAGS) $(SHARED) $$(pkg-config --cflags libcurl) client/c/http.c -o lib/libflux_client_http.$(SUFFIX) $$(pkg-config --libs libcurl) -pthread
