#!/bin/sh
# Load the whole tree and every test file, then run them.
# plunit does not compile test units when `-O` is on, so this one runs plain.
#
# The `-g` matters: once swipl sees a bare file name, everything after it is an
# argument for the program rather than an option for swipl.
set -e
cd "$(dirname "$0")"
exec swipl -q \
     -g "consult(['test/lexer.plt', 'test/parser.plt', 'test/typecheck.plt', 'test/middle.plt', 'test/allocator.plt', 'test/programs.plt', 'test/random.plt'])" \
     -g 'set_test_options([format(log), silent(false)])' \
     -g '(run_tests -> halt(0) ; halt(1))' \
     -t 'halt(1)' </dev/null
