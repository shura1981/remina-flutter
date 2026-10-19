#!/usr/bin/env bash
# Production export of the generated artwork: normalize canvas, clip the native
# rounded tile contour, and emit the PNG sizes required by the macOS catalog.
set -euo pipefail
cd "$(dirname "$0")/.."
command -v convert >/dev/null || { echo 'Se requiere ImageMagick (convert).' >&2; exit 1; }
task_icon_tmp="$(mktemp -d)"
trap 'rm -rf "$task_icon_tmp"' EXIT
convert assets/branding/source/remina-macos-generated.png \
  -resize 1024x1024 -strip "$task_icon_tmp/artwork.png"
# Clip only the exterior fringe; leave the generated interior and alpha intact.
convert -size 4096x4096 xc:none -fill white \
  -draw 'roundrectangle 308,308 3784,3768 712,712' \
  -resize 1024x1024 "$task_icon_tmp/contour.png"
convert "$task_icon_tmp/artwork.png" "$task_icon_tmp/contour.png" \
  -compose DstIn -composite -strip assets/branding/remina-macos.png
for task_icon_size in 16 32 64 128 256 512 1024; do
  convert assets/branding/remina-macos.png -filter Lanczos \
    -resize "${task_icon_size}x${task_icon_size}" -strip \
    "macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_${task_icon_size}.png"
done
for task_icon_size in 64 128 256; do
  convert assets/branding/remina-macos.png -filter Lanczos \
    -resize "${task_icon_size}x${task_icon_size}" -strip \
    "assets/branding/remina-mark-${task_icon_size}.png"
done
convert assets/branding/remina-macos.png -define icon:auto-resize=256,128,64,48,32,16 \
  windows/runner/resources/app_icon.ico
echo 'Exportados: master 1024 px, marca 64/128/256 px, catálogo macOS 16–1024 px y Windows app_icon.ico.'
