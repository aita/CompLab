#!/bin/sh
# Compile the tree and the tests, then run them.
set -e
cd "$(dirname "$0")"
exec sbcl --noinform --disable-debugger --load build.lisp --eval '
  (progn (build)
         (build :files (list "harness" "lexer" "parser" "typecheck" "middle"
                             "allocator" "oracle" "random" "programs")
                :root "test/")
         (sb-ext:exit :code (if (funcall (find-symbol "RUN-SUITE" "WOLV.TEST")) 0 1)))'
