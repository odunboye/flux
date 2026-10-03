#!/bin/sh
# Repository-local application CLI; public package distribution is forthcoming.
exec python3 "$(dirname "$0")/tools/flux.py" "$@"
