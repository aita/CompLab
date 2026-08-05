#!/bin/sh
# Compile the system and dump an executable image at bin/wolv.
#
# The system is described once, in wolv.asd, and ASDF is what reads it.  A
# saved image is how a Common Lisp program becomes a command: everything is
# already compiled and the heap is already built, so `bin/wolv` starts in a few
# milliseconds rather than compiling itself first.
set -e
cd "$(dirname "$0")"
mkdir -p bin
exec sbcl --noinform --disable-debugger \
     --eval '(require :asdf)' \
     --eval '(asdf:load-asd (merge-pathnames "wolv.asd" (uiop:getcwd)))' \
     --eval '(handler-bind ((warning (function muffle-warning))) (asdf:load-system "wolv"))' \
     --eval '(setf uiop:*image-entry-point* (read-from-string "wolv.cli:toplevel"))' \
     --eval '(uiop:dump-image "bin/wolv" :executable t)'
