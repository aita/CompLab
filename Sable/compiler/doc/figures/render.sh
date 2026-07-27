#!/bin/sh
# Regenerate the images the documents link to.  Needs graphviz.
#
# PNG, not SVG.  These figures are almost entirely text, and Zed's markdown
# preview does not render text inside an SVG (zed-industries/zed#21319), so an
# SVG here shows as a set of empty boxes.  Nothing is lost by rasterising: the
# reviewable text of a figure is its .dot, which is what a diff should be read
# on anyway -- the image is a build artifact that happens to be committed.
#
# 144 dpi is 1.5x, so the images stay sharp when a viewer scales them down to
# the width of the text.
#
# The PNGs are committed so that the documents render on a machine without
# graphviz; run this after editing any .dot and commit the result.

set -e
cd "$(dirname "$0")"
for source in *.dot; do
  # `dot` honours a `layout = neato` line inside the file, so one
  # command covers both engines.
  dot -Tpng -Gdpi=144 "$source" -o "${source%.dot}.png"
  echo "${source%.dot}.png"
done
