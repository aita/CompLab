#!/bin/sh
# Run every benchmark three ways and compare them.
#
# The comparison is the reason this script exists.  A number from `skunkllvm`
# that does not match the number from `skunk` is not a fast program, it is a
# wrong one, so the table is only worth reading once every row ends in the same
# checksum.  Everything a benchmark prints counts, including the declarations
# the top level echoes: the two halves are supposed to agree byte for byte, not
# approximately.
#
# `-O0` is in the table because it is the honest floor.  It is what the front
# end wrote, selected and allocated by LLVM and otherwise untouched, so the gap
# between the two columns is what `default<O2>` is worth on this program -- and
# `-O0` finishing at all is what says `musttail` is doing its job, since
# LLVM's own sibling-call optimisation does not run there.
#
# The instruction count is the `-S` output with the directives stripped out,
# the basis included, which makes it a size to compare against itself over time
# rather than an absolute.  Wall time is a single run; it is stable to a few per
# cent here, and averaging would only hide the interpreter's cost, which is the
# other thing worth seeing.

set -u

cd "$(dirname "$0")/.." || exit 1

skunk=./_build/default/src/interpreter/skunk.exe
skunkllvm=./_build/default/src/llvm/skunkllvm.exe

if [ ! -x "$skunk" ] || [ ! -x "$skunkllvm" ]; then
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

printf '%-10s %8s %8s %10s %8s   %s\n' benchmark -O2 -O0 interp instrs output
printf '%-10s %8s %8s %10s %8s   %s\n' ---------- ------ ------ -------- ------ ------

for src in bench/*.sk; do
  name=$(basename "$src" .sk)

  for opt in O2 O0; do
    if ! "$skunkllvm" "-$opt" -o "$tmp/$name.$opt" "$src" > "$tmp/build.log" 2>&1; then
      printf '!! %s: skunkllvm -%s failed\n' "$name" "$opt"
      sed 's/^/     /' "$tmp/build.log"
      failed=1
      continue 2
    fi
  done

  t0=$(date +%s%N)
  "$tmp/$name.O2" > "$tmp/o2.out" 2>&1
  t1=$(date +%s%N)

  s0=$(date +%s%N)
  "$tmp/$name.O0" > "$tmp/o0.out" 2>&1
  s1=$(date +%s%N)

  u0=$(date +%s%N)
  "$skunk" "$src" > "$tmp/interp.out" 2>&1
  u1=$(date +%s%N)

  "$skunkllvm" -S -o "$tmp/$name.s" "$src" 2>/dev/null
  instrs=$(grep -c '^	[a-z]' "$tmp/$name.s")

  if cmp -s "$tmp/o2.out" "$tmp/interp.out" && cmp -s "$tmp/o0.out" "$tmp/interp.out"; then
    status=$(tail -n 1 "$tmp/o2.out")
  else
    status='MISMATCH'
    failed=1
  fi

  printf '%-10s %8s %8s %10s %8s   %s\n' \
    "$name" "$(elapsed "$t0" "$t1")" "$(elapsed "$s0" "$s1")" \
    "$(elapsed "$u0" "$u1")" "$instrs" "$status"

  if [ "$status" = MISMATCH ]; then
    echo
    echo "!! $name: the three do not agree"
    diff -u "$tmp/interp.out" "$tmp/o2.out" |
      sed -e '1s/.*/     --- interpreted/' -e '2s/.*/     +++ compiled/' -e '3,$s/^/     /' |
      head -n 40
    echo
  fi
done

if [ "$failed" -ne 0 ]; then
  echo
  echo '!! at least one benchmark did not agree with itself'
  exit 1
fi
