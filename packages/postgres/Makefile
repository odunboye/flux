CC ?= cc
CFLAGS ?= -O2 -Wall -Wextra -Werror -std=c11
ifeq ($(shell uname -s),Darwin)
SHARED_FLAGS = -dynamiclib
SUFFIX = dylib
else
SHARED_FLAGS = -shared -fPIC
SUFFIX = so
endif
.PHONY: native
native:
	mkdir -p lib
	$(CC) $(CFLAGS) $(SHARED_FLAGS) c/pg_transport.c -o lib/libidris2_pg_transport.$(SUFFIX)
