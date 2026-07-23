#!/bin/zsh

set -euo pipefail

root="${0:A:h:h}"
work="$(mktemp -d /private/tmp/coda-icon.XXXXXX)"
trap 'rm -rf "$work"' EXIT

source_png="$work/CodaAppIcon.png"
CLANG_MODULE_CACHE_PATH="/private/tmp/coda-icon-clang-cache" \
  SWIFT_MODULE_CACHE_PATH="/private/tmp/coda-icon-swift-cache" \
  swift "$root/scripts/render-icon.swift" "$root/Support/CodaAppIcon.svg" "$source_png"
iconset="$work/Coda.iconset"
mkdir -p "$iconset"

sips -z 16 16 "$source_png" --out "$iconset/icon_16x16.png" >/dev/null
sips -z 32 32 "$source_png" --out "$iconset/icon_16x16@2x.png" >/dev/null
sips -z 32 32 "$source_png" --out "$iconset/icon_32x32.png" >/dev/null
sips -z 64 64 "$source_png" --out "$iconset/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "$source_png" --out "$iconset/icon_128x128.png" >/dev/null
sips -z 256 256 "$source_png" --out "$iconset/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "$source_png" --out "$iconset/icon_256x256.png" >/dev/null
sips -z 512 512 "$source_png" --out "$iconset/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "$source_png" --out "$iconset/icon_512x512.png" >/dev/null
cp "$source_png" "$iconset/icon_512x512@2x.png"

iconutil -c icns -o "$root/Support/Coda.icns" "$iconset"
print "$root/Support/Coda.icns"
