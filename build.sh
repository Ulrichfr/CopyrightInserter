#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

SDK="$(xcrun --sdk macosx --show-sdk-path)"
pkill -x CopyrightInserter >/dev/null 2>&1 || true

echo "Test du compositeur"
swiftc -parse-as-library \
  -sdk "$SDK" \
  -target arm64-apple-macos14 \
  -framework CoreGraphics \
  -framework CoreText \
  -framework ImageIO \
  -o /tmp/marque-compositor-test \
  Sources/Compositor.swift \
  Tests/main.swift
/tmp/marque-compositor-test

ICONSET="Resources/AppIcon.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "Resources/icon-1024.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "$double" "$double" "Resources/icon-1024.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "Resources/AppIcon.icns"
rm -rf "$ICONSET"

APP="dist/Copyright Inserter.app"
rm -rf dist "Copyright Inserter.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

echo "Compilation"
swiftc -parse-as-library -O \
  -sdk "$SDK" \
  -target arm64-apple-macos14 \
  -framework SwiftUI \
  -framework AppKit \
  -framework CoreGraphics \
  -framework CoreText \
  -framework ImageIO \
  -o "$APP/Contents/MacOS/CopyrightInserter" \
  Sources/Compositor.swift \
  Sources/MarqueApp.swift

codesign --force --deep --sign - "$APP"

STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/Copyright Inserter.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create \
  -volname "Copyright Inserter" \
  -srcfolder "$STAGE" \
  -ov \
  -format UDZO \
  "../Copyright Inserter.dmg" >/dev/null
rm -rf "$STAGE"

echo "OK: $PWD/$APP"
echo "DMG: $(cd .. && pwd)/Copyright Inserter.dmg"
