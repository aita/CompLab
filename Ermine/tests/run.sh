#!/bin/sh
# Runs everything: the assertion suite under both kernels, the golden outputs,
# and a saved image against the same goldens the fresh system produced.
set -eu
cd "$(dirname "$0")/.."

fails=0
ok()   { printf '  ok    %s\n' "$1"; }
bad()  { printf '  FAIL  %s\n' "$1"; fails=$((fails + 1)); }

for bin in ./ermine ./ermine-switch; do
  [ -x "$bin" ] || { echo "$bin is not built; run make"; exit 1; }
done

echo "assertions"
for bin in ./ermine ./ermine-switch; do
  if out=$("$bin" tests/suite.erm </dev/null 2>&1); then
    ok "$bin $(echo "$out" | tail -1)"
  else
    printf '%s\n' "$out"
    bad "$bin tests/suite.erm"
  fi
done

echo "golden output"
golden() { # golden <file.erm> <file.out> <binary...>
  src=$1; want=$2; shift 2
  for bin in "$@"; do
    if "$bin" "$src" </dev/null 2>&1 | diff -u "$want" - >/tmp/ermine-diff.$$; then
      ok "$bin $src"
    else
      head -20 /tmp/ermine-diff.$$
      bad "$bin $src"
    fi
    rm -f /tmp/ermine-diff.$$
  done
}

golden tests/golden.erm tests/golden.out ./ermine ./ermine-switch
golden examples/sieve.erm examples/sieve.out ./ermine ./ermine-switch
golden examples/mandel.erm examples/mandel.out ./ermine ./ermine-switch
golden examples/life.erm examples/life.out ./ermine ./ermine-switch
# The tour reports which dispatch it is running under, so it is its own answer
# only under the kernel that produced the file.
golden examples/tour.erm examples/tour.out ./ermine

echo "saved image"
img=$(mktemp -u /tmp/ermine-XXXXXX.img)
./ermine -e "s\" $img\" save-image bye" </dev/null
if ./ermine --image "$img" tests/golden.erm </dev/null 2>&1 | diff -u tests/golden.out - >/dev/null; then
  ok "--image reproduces tests/golden.out"
else
  bad "--image reproduces tests/golden.out"
fi
if ./ermine --image "$img" tests/suite.erm </dev/null >/dev/null 2>&1; then
  ok "--image passes the assertions"
else
  bad "--image passes the assertions"
fi
# The two kernels differ in dispatch, not in their primitive table, so an
# image crosses between them.
if ./ermine-switch --image "$img" tests/suite.erm </dev/null >/dev/null 2>&1; then
  ok "an image saved by one dispatch runs under the other"
else
  bad "an image saved by one dispatch runs under the other"
fi
if ./ermine --image /dev/null -e 'bye' >/dev/null 2>&1; then
  bad "a file that is not an image is refused"
else
  ok "a file that is not an image is refused"
fi
rm -f "$img"

echo
if [ "$fails" -eq 0 ]; then
  echo "all checks passed"
else
  echo "$fails failed"
  exit 1
fi
