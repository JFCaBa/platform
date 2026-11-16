#!/usr/bin/env bash
# Renders the What Platform icon SVGs to PNG (Chrome headless for faithful SVG, ImageMagick for post-processing).
set -euo pipefail
cd "$(dirname "$0")"
CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
OUT=.
shot() { # svg width height out.png
  "$CHROME" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=1 \
    --default-background-color=00000000 --window-size="$2,$3" \
    --screenshot="$PWD/$4" "file://$PWD/$1" >/dev/null 2>&1
}
shot icon.svg 1024 1024 ./icon-raw.png
shot foreground.svg 1024 1024 ./foreground-1024.png
shot feature.svg 1024 500 ./feature-raw.png
magick ./icon-raw.png -background "#1E3A8A" -alpha remove -alpha off ./icon-1024.png   # App Store: no alpha
magick ./icon-1024.png -resize 512x512 ./play-512.png
magick ./feature-raw.png -background "#1E3A8A" -alpha remove -alpha off ./feature-1024x500.png
rm ./icon-raw.png ./feature-raw.png
for f in ./*.png; do magick identify -format "%f %w %h opaque=%[opaque]\n" "$f"; done
