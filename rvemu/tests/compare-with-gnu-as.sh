#!/bin/sh
# Assemble tests/isa.s two ways -- with GNU as, and with rvemu's own assembler --
# and check that rvemu disassembles both to exactly the same instructions.
#
# This is the check behind the claim in the README. It needs a RISC-V binutils
# and is therefore not part of `ctest`; run it by hand after touching the
# assembler or the encoder.
#
#   tests/compare-with-gnu-as.sh [path/to/rvemu]

set -e
here=$(dirname "$0")
rvemu=${1:-$here/../build/rvemu}
as=${AS:-riscv64-linux-gnu-as}
ld=${LD:-riscv64-linux-gnu-ld}

for tool in "$as" "$ld"; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "skip: $tool not found"
    exit 0
  }
done

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

"$as" -march=rv64imafd_zifencei -mno-relax "$here/isa.s" -o "$work/isa.o"
"$ld" -Ttext=0x10000 -e _start "$work/isa.o" -o "$work/isa.elf"

# Both sides are disassembled by rvemu, so any difference is a difference in the
# bytes. Start at _start: the linked ELF also maps its own headers as text.
strip_addrs() { sed -n '/<_start>:/,$p' | sed 's/^ *0x[0-9a-f]*:	//'; }
"$rvemu" -d "$work/isa.elf" | strip_addrs > "$work/gnu.txt"
"$rvemu" -d -a "$here/isa.s" | strip_addrs > "$work/rvemu.txt"

if diff -u "$work/gnu.txt" "$work/rvemu.txt"; then
  echo "ok: $(grep -c . "$work/rvemu.txt") lines identical to GNU as"
else
  echo "FAILED: the assemblers disagree"
  exit 1
fi
