#!/bin/bash
# Builds MacDroid.app (universal if the toolchain allows) and zips it for the website.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "→ building icon"
mkdir -p build
swift scripts/make-icon.swift build/icon-1024.png
ICONSET=build/AppIcon.iconset
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s build/icon-1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2))
  sips -z $d $d build/icon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o build/AppIcon.icns

echo "→ building binary"
cd macos
if swift build -c release --arch arm64 --arch x86_64 2>/dev/null; then
  BIN=.build/apple/Products/Release/MacDroid
  echo "   universal (arm64 + x86_64)"
else
  swift build -c release
  BIN=.build/release/MacDroid
  echo "   single-arch fallback"
fi
cd ..

echo "→ assembling MacDroid.app"
APP=build/MacDroid.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "macos/$BIN" "$APP/Contents/MacOS/MacDroid"
cp macos/Resources/Info.plist "$APP/Contents/Info.plist"
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --deep -s - "$APP"

mkdir -p website/downloads
ditto -c -k --keepParent "$APP" website/downloads/MacDroid.app.zip
echo "✓ website/downloads/MacDroid.app.zip"
