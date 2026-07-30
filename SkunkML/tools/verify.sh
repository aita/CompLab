#!/bin/sh
# Every program in examples/ and tests/, compiled three ways and diffed against
# the interpreter.  `reals.sk` is left out: the back end has no representation
# for a real, so there is no compiled half to diff.
set -u
cd "$(dirname "$0")/.." || exit 1
skunk=./_build/default/src/interpreter/skunk.exe
skunkc=./_build/default/src/compiler/skunkc.exe
tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp"' EXIT INT TERM
n=0
bad=0
# Both back ends print match warnings before the program runs; they are a fact
# about the source rather than about the code, so they are not part of what the
# two halves have to agree on byte for byte.
nowarn() { grep -v ': warning: ' "$1" > "$1.clean"; mv "$1.clean" "$1"; }

for src in examples/*.sk tests/*.sk; do
  case $src in */reals.sk) continue;; esac
  "$skunk" "$src" > "$tmp/interp" 2>&1
  nowarn "$tmp/interp"
  for mode in plain dynamic no-opt; do
    case $mode in
      plain) set --;;
      dynamic) set -- --dynamic;;
      no-opt) set -- --no-opt;;
    esac
    n=$((n + 1))
    if ! "$skunkc" "$@" -o "$tmp/bin" "$src" > "$tmp/log" 2>&1; then
      echo "!! $src [$mode]: skunkc failed"; sed 's/^/     /' "$tmp/log"; bad=$((bad + 1)); continue
    fi
    "$tmp/bin" > "$tmp/out" 2>&1
    nowarn "$tmp/out"
    if ! cmp -s "$tmp/interp" "$tmp/out"; then
      echo "!! $src [$mode]: differs"
      diff "$tmp/interp" "$tmp/out" | head -n 12
      bad=$((bad + 1))
    fi
  done
done

# The three runtime errors, whose message has to be the same message from both
# back ends -- text and exit status.
for src in tests/errors/bounds.sk tests/errors/bounds0.sk tests/errors/divzero.sk; do
  "$skunk" "$src" > "$tmp/interp" 2>&1
  echo "status $?" >> "$tmp/interp"
  "$skunkc" -o "$tmp/bin" "$src" > /dev/null 2>&1
  "$tmp/bin" > "$tmp/out" 2>&1
  echo "status $?" >> "$tmp/out"
  n=$((n + 1))
  if ! cmp -s "$tmp/interp" "$tmp/out"; then
    echo "!! $src: differs"
    diff "$tmp/interp" "$tmp/out"
    bad=$((bad + 1))
  fi
done

echo "$n comparisons, $bad bad"
[ "$bad" -eq 0 ]
