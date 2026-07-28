#!/bin/sh
# Compile a MartenML program, link it against the runtime and run it under qemu.
#
# Every program is built twice: once with the whole register file and once with
# `-nregs 10`, which forces the allocator to spill.  The two builds have to
# agree, so the golden file checks the spiller as well as the program.
#
# usage: run.sh <martenmlc> <runtime.c> <source.mml>

set -e

martenmlc=$1
runtime=$2
source=$3

for tool in riscv64-linux-gnu-gcc qemu-riscv64; do
  if ! command -v "$tool" > /dev/null; then
    echo "$tool is required to run these tests" >&2
    exit 1
  fi
done

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

"$martenmlc" -o "$work/wide.s" "$source" 2> "$work/warnings"
"$martenmlc" -nregs 10 -o "$work/narrow.s" "$source" 2> /dev/null

riscv64-linux-gnu-gcc -static -o "$work/wide" "$work/wide.s" "$runtime"
riscv64-linux-gnu-gcc -static -o "$work/narrow" "$work/narrow.s" "$runtime"

set +e
qemu-riscv64 "$work/wide" > "$work/wide.out" 2> "$work/wide.err"
wide_status=$?
qemu-riscv64 "$work/narrow" > "$work/narrow.out" 2> "$work/narrow.err"
narrow_status=$?
set -e

if ! cmp -s "$work/wide.out" "$work/narrow.out" || [ "$wide_status" != "$narrow_status" ]
then
  echo "the full-register and 10-register builds disagree:"
  diff "$work/wide.out" "$work/narrow.out" || true
  echo "exit status: $wide_status vs $narrow_status"
  exit 1
fi

cat "$work/warnings"
cat "$work/wide.out"
cat "$work/wide.err"
[ "$wide_status" = 0 ] || echo "exit status: $wide_status"
