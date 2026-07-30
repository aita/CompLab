#!/bin/sh
# Run every benchmark through both back ends and compare them.
#
# The comparison is the reason this script exists.  A number from `skunkc` that
# does not match the number from `skunk` is not a fast program, it is a wrong
# one, so the table is only worth reading once every row says `ok`.  Everything
# a benchmark prints counts, including the declarations the top level echoes:
# the two back ends are supposed to agree byte for byte, not approximately.
#
# The instruction count is `--dump-mach` with the structure stripped out -- one
# line per machine instruction after register allocation, the basis included,
# which makes it a size to compare against itself over time rather than an
# absolute.  Wall time is a single run; it is stable to a few per cent here,
# and averaging would only hide the interpreter's cost, which is the other
# thing worth seeing.

set -u

cd "$(dirname "$0")/.." || exit 1

skunk=./_build/default/src/interpreter/skunk.exe
skunkc=./_build/default/src/compiler/skunkc.exe

if [ ! -x "$skunk" ] || [ ! -x "$skunkc" ]; then
  echo "run.sh: build first -- dune build" >&2
  exit 1
fi

tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp"' EXIT INT TERM

# Seconds, to milliseconds, without pulling in anything but date(1).
elapsed() {
  awk -v a="$1" -v b="$2" 'BEGIN { printf "%.3f", (b - a) / 1000000000 }'
}

failed=0

printf '%-10s %10s %10s %8s   %s\n' benchmark compiled interp instrs output
printf '%-10s %10s %10s %8s   %s\n' ---------- -------- -------- ------ ------

for src in bench/*.sk; do
  name=$(basename "$src" .sk)
  exe=$tmp/$name

  if ! "$skunkc" -o "$exe" "$src" > "$tmp/build.log" 2>&1; then
    printf '!! %s: skunkc failed\n' "$name"
    sed 's/^/     /' "$tmp/build.log"
    failed=1
    continue
  fi

  t0=$(date +%s%N)
  "$exe" > "$tmp/compiled.out" 2>&1
  t1=$(date +%s%N)

  u0=$(date +%s%N)
  "$skunk" "$src" > "$tmp/interp.out" 2>&1
  u1=$(date +%s%N)

  # --dump-mach still writes an executable, so send it somewhere disposable.
  instrs=$("$skunkc" --dump-mach -o "$tmp/mach.bin" "$src" 2>/dev/null |
             grep -cv '^func\|^  b\|^$')

  if cmp -s "$tmp/compiled.out" "$tmp/interp.out"; then
    status=$(tail -n 1 "$tmp/compiled.out")
  else
    status='MISMATCH'
    failed=1
  fi

  printf '%-10s %10s %10s %8s   %s\n' \
    "$name" "$(elapsed "$t0" "$t1")" "$(elapsed "$u0" "$u1")" "$instrs" "$status"

  if [ "$status" = MISMATCH ]; then
    echo
    echo "!! $name: the two back ends disagree"
    diff -u "$tmp/interp.out" "$tmp/compiled.out" |
      sed -e '1s/.*/     --- interpreted/' -e '2s/.*/     +++ compiled/' -e '3,$s/^/     /' |
      head -n 40
    echo
  fi
done

if [ "$failed" -ne 0 ]; then
  echo
  echo '!! at least one benchmark did not agree with itself across the two back ends'
  exit 1
fi
