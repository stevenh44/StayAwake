#!/bin/bash
# Build StayAwake.app and package it as a drag-to-Applications DMG.
set -euo pipefail
cd "$(dirname "$0")"

./build.sh

rm -rf dist
mkdir -p dist/dmg-root
cp -R StayAwake.app dist/dmg-root/
ln -s /Applications dist/dmg-root/Applications

hdiutil create -volname StayAwake -srcfolder dist/dmg-root -ov -format UDZO dist/StayAwake.dmg
rm -rf dist/dmg-root

echo "Done: dist/StayAwake.dmg"
