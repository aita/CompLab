#!/bin/sh
# Compile the namespaces ahead of time, and remember the classpath.
#
# Nothing needs this — `clojure -M -m wolv.cli` runs the tree from source — but
# it compiles every namespace on the way up, and `compare.sh` starts the
# compiler four hundred times.  With the classes on disk `bin/wolv` is a plain
# `java` invocation.
set -e
cd "$(dirname "$0")"
mkdir -p classes
clojure -Spath > .classpath
clojure -M -e "(binding [*compile-path* \"classes\"] (compile 'wolv.cli))" > /dev/null
