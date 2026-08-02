#!/bin/sh
# Regenerate the images the documents link to.  Needs graphviz.
#
# PNG, not SVG, for the reason the sibling MartenML gives: these figures are
# almost entirely text, and some markdown previews do not render text inside an
# SVG.  Nothing is lost -- the reviewable text of a figure is its .dot, which is
# what a diff should be read on; the image is a build artifact that happens to
# be committed so that the documents render on a machine without graphviz.
#
# 144 dpi is 1.5x, so the images stay sharp when a viewer scales them down to
# the width of the text.
#
# Run this after editing any .dot, and commit the result.

set -e
cd "$(dirname "$0")"
for source in *.dot; do
  dot -Tpng -Gdpi=144 "$source" -o "${source%.dot}.png"
  echo "${source%.dot}.png"
done
