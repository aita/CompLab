#!/bin/sh
# Save a state at bin/wolv, so that the command starts without loading the tree
# first.  `swipl wolv.pl -- ...` runs the same compiler from source.
#
# The `-l` matters: once swipl sees a bare file name, everything after it is an
# argument for the program rather than an option for swipl.
set -e
cd "$(dirname "$0")"
mkdir -p bin
exec swipl -q -O -l wolv.pl \
     -g 'qsave_program("bin/wolv", [goal(main), toplevel(halt), stand_alone(true)])' \
     -t 'halt(0)'
