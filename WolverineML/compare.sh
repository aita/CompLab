#!/usr/bin/env bash
# Compare every stage dump of a port against `python --regalloc graph`.
#
#   ./compare.sh lisp/bin/wolv            # or any command that takes wolv's arguments
#
# 10 stages x 10 programs x 4 configurations.  Must run under bash: fish does
# not word-split "$cfg", so `--max-regs 12` would arrive as one argument and
# every spilling comparison would fail for the wrong reason.
set -u
cd "$(dirname "$0")"

PORT=${1:?usage: compare.sh <command>}
shift || true

STAGES=(tokens ast ir ssa opt dag mach flat ra asm)
PROGRAMS=(racket/examples/tour.wol racket/examples/queens.wol racket/examples/sort.wol)
for p in racket/test/programs/*.wol; do PROGRAMS+=("$p"); done

CONFIGS=("" "--no-opt" "--no-checks" "--max-regs 12")

pass=0
fail=0
for cfg in "${CONFIGS[@]}"; do
  for prog in "${PROGRAMS[@]}"; do
    for stage in "${STAGES[@]}"; do
      want=$( (cd python && uv run python -m wolv emit -s "$stage" --regalloc graph $cfg "../$prog") 2>&1 )
      got=$( $PORT "$@" emit -s "$stage" $cfg "$prog" 2>&1 )
      if [[ "$want" == "$got" ]]; then
        pass=$((pass + 1))
      else
        fail=$((fail + 1))
        echo "MISMATCH  $stage  $prog  [${cfg:-default}]"
        if [[ -n "${VERBOSE:-}" ]]; then
          diff <(printf '%s\n' "$want") <(printf '%s\n' "$got") | head -20
        fi
      fi
    done
  done
done
echo "$pass/$((pass + fail)) dumps match"
[[ $fail -eq 0 ]]
