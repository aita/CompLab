#!/bin/sh
# Regenerate the images the documents link to.  Needs graphviz.
#
# SVG rather than PNG: a PNG is a binary blob, so a diff of one says only that
# it changed, and review tools will not show it.  The cost is that an SVG names
# its fonts rather than carrying them, so text can shift on a machine without
# Helvetica -- the labels are kept short enough to survive that.
#
# The SVGs are committed so that the documents render on a machine without
# graphviz; run this after editing any .dot and commit the result.

set -e
cd "$(dirname "$0")"
for source in *.dot; do
  dot -Tsvg "$source" -o "${source%.dot}.svg"
  echo "${source%.dot}.svg"
done
