#!/bin/bash
# Build StayAwake.app from source. Requires Xcode Command Line Tools.
set -euo pipefail
cd "$(dirname "$0")"

echo "Rendering app icon…"
swift makeicon.swift
mkdir -p AppIcon.iconset
for s in 16 32 128 256 512; do
  sips -z "$s" "$s" icon_1024.png --out "AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2))
  sips -z "$d" "$d" icon_1024.png --out "AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns AppIcon.iconset
rm -rf AppIcon.iconset icon_1024.png

echo "Compiling…"
mkdir -p StayAwake.app/Contents/MacOS StayAwake.app/Contents/Resources
swiftc -O main.swift -o StayAwake.app/Contents/MacOS/StayAwake -framework Cocoa
cp Info.plist StayAwake.app/Contents/Info.plist
mv AppIcon.icns StayAwake.app/Contents/Resources/AppIcon.icns

echo "Signing (ad-hoc)…"
codesign --force --sign - StayAwake.app

echo "Done: $(pwd)/StayAwake.app"
echo "Launch it with: open StayAwake.app"
