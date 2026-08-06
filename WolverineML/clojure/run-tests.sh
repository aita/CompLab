#!/bin/sh
# Run every suite under test/.
set -e
cd "$(dirname "$0")"
exec clojure -M:test
