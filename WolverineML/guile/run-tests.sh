#!/bin/sh
# Run every suite under test/, and say which ones failed.
#
# One process each, because a suite leaves an exit status behind it and that is
# the only thing a shell can read.  `make.sh` first, if there is no ccache yet,
# because interpreting the compiler makes the end-to-end tests very slow.
set -u
cd "$(dirname "$0")"

[ -d ccache ] || ./make.sh

failed=0
for suite in lexer parser typecheck middle allocator programs random; do
  GUILE_AUTO_COMPILE=0 guile -L src -L test -C ccache -s "test/$suite.scm" || failed=1
done
exit $failed
