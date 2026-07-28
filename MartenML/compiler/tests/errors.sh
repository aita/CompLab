#!/bin/sh
# Every program named on the command line must be rejected by the compiler.
# Their messages are collected into one golden file.
#
# usage: errors.sh <martenmlc> <source.mml>...

martenmlc=$1
shift

status=0
for source in "$@"; do
  echo "--- $(basename "$source")"
  if "$martenmlc" -o /dev/null "$source" 2>&1; then
    echo "!!! the compiler accepted this program"
    status=1
  fi
done
exit $status
