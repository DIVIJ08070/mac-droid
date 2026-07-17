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

echo "→ assembling Bifrost.app"
APP=build/Bifrost.app
rm -rf "$APP" build/MacDroid.app
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# The executable inside stays "MacDroid" to match CFBundleExecutable; only the
# bundle and display name are "Bifrost".
cp "macos/$BIN" "$APP/Contents/MacOS/MacDroid"
cp macos/Resources/Info.plist "$APP/Contents/Info.plist"
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Sign with a stable self-signed identity so macOS keeps Screen Recording and
# other permissions across rebuilds (ad-hoc signing changes identity each build,
# which makes macOS forget the grant). Falls back to ad-hoc if the cert is absent.
# Strip extended attributes/Finder metadata — codesign rejects them as "detritus".
xattr -cr "$APP"

SIGN_KC="$HOME/Library/Keychains/macdroid-signing.keychain-db"
# The ONE stable self-signed cert every release MUST use. Its leaf is baked into
# the in-app updater's signature gate and into every granted TCC permission, so
# signing with a different cert breaks auto-update AND resets Screen Recording /
# Accessibility / Notifications for every existing user. The build therefore
# fails loudly rather than silently shipping a mismatched (or ad-hoc) signature.
EXPECTED_LEAF="f00d88463c9e5045e1b77f5ae14e136c2566827e"

security unlock-keychain -p macdroid "$SIGN_KC" 2>/dev/null || true
if ! security find-identity -p codesigning "$SIGN_KC" 2>/dev/null | grep -q "MacDroid Self-Signed"; then
  echo "✗ Stable signing identity 'MacDroid Self-Signed' not found in $SIGN_KC." >&2
  echo "  Refusing to ad-hoc sign — that would break auto-update + reset permissions." >&2
  exit 1
fi
codesign --force --deep -s "MacDroid Self-Signed" --keychain "$SIGN_KC" "$APP"

LEAF=$(codesign -d -r- "$APP" 2>/dev/null | sed -n 's/.*certificate leaf = H"\([^"]*\)".*/\1/p' | tr 'A-F' 'a-f')
if [ "$LEAF" != "$EXPECTED_LEAF" ]; then
  echo "✗ Signed with the WRONG cert (leaf ${LEAF:-none}, expected $EXPECTED_LEAF)." >&2
  echo "  This build would break auto-update for existing users. Aborting." >&2
  exit 1
fi
echo "   signed with the stable identity (leaf $LEAF) ✓"

mkdir -p website/downloads
rm -f website/downloads/MacDroid.app.zip
ditto -c -k --keepParent "$APP" website/downloads/Bifrost.app.zip
echo "✓ website/downloads/Bifrost.app.zip"
