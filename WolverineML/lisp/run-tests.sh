#!/bin/sh
# Run the tests, through ASDF, which is where the test system is described.
set -e
cd "$(dirname "$0")"
exec sbcl --noinform --disable-debugger \
     --eval '(require :asdf)' \
     --eval '(asdf:load-asd (merge-pathnames "wolv.asd" (uiop:getcwd)))' \
     --eval '(handler-bind ((warning (function muffle-warning))) (asdf:test-system "wolv"))' \
     --eval '(uiop:quit 0)'
