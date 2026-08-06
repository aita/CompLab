#!/bin/sh
# Compile every module into ccache/, which is where bin/wolv looks.
#
# Nothing needs this — Guile runs the tree from source — but interpreting a
# compiler is about twenty times slower than running the bytecode, and
# `compare.sh` runs it four hundred times.
set -e
cd "$(dirname "$0")"
mkdir -p ccache/wolv
for f in src/wolv/*.scm; do
  name=$(basename "$f" .scm)
  guild compile -L src -O2 -o "ccache/wolv/$name.go" "$f"
done
