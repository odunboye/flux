CC ?= cc
CFLAGS ?= -O2 -Wall -Wextra -Werror -std=c11
PKG_CONFIG ?= pkg-config
ifeq ($(shell uname -s),Darwin)
SHARED = -dynamiclib
SUFFIX = dylib
else
SHARED = -shared -fPIC
SUFFIX = so
endif
.PHONY: native
native:
	$(PKG_CONFIG) --atleast-version=1.0.18 libsodium
	mkdir -p lib
	$(CC) $(CFLAGS) $(SHARED) $$( $(PKG_CONFIG) --cflags libsodium ) c/auth_crypto.c -o lib/libflux_auth.$(SUFFIX) $$( $(PKG_CONFIG) --libs libsodium ) -pthread
