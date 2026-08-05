#!/bin/sh
# Compile the tree and dump an executable image at bin/wolv.
#
# A saved image is how a Common Lisp program becomes a command: everything is
# already compiled and the heap is already built, so `bin/wolv` starts in a few
# milliseconds rather than compiling itself first.
set -e
cd "$(dirname "$0")"
mkdir -p bin
exec sbcl --noinform --disable-debugger --load build.lisp --eval '
  (progn (build)
         (sb-ext:save-lisp-and-die "bin/wolv"
                                   :executable t
                                   :save-runtime-options t
                                   :toplevel (lambda () (funcall (find-symbol "TOPLEVEL" "WOLV.CLI")))))'
