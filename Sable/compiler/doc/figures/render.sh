#!/bin/sh
# Regenerate the SVGs the documents link to.  Needs graphviz.
#
# The SVGs are committed so that the documents render on a machine without
# graphviz; run this after editing any .dot and commit the result.

set -e
cd "$(dirname "$0")"
for source in *.dot; do
  dot -Tsvg "$source" -o "${source%.dot}.svg"
  echo "${source%.dot}.svg"
done
