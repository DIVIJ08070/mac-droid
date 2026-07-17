#!/bin/bash
# Verify the published downloads are signed with the ONE canonical key per
# platform (see SIGNING.md). Run before pushing a release — a drift here means
# auto-update will break and permissions will reset for existing users.
set -uo pipefail
cd "$(dirname "$0")/.."

APK="website/downloads/bifrost.apk"
MACZIP="website/downloads/Bifrost.app.zip"
EXPECT_APK="9af8408f832cd5eb571c55168a3325165b92ddd81cc3bf59dccbcd5d14a6c38a"
EXPECT_MAC="f00d88463c9e5045e1b77f5ae14e136c2566827e"

fail=0

# --- Android APK ---
APKSIGNER=$(ls "$HOME/Library/Android/sdk/build-tools"/*/apksigner 2>/dev/null | sort -V | tail -1)
if [ -z "$APKSIGNER" ]; then
  echo "⚠  apksigner not found — skipping APK check"
elif [ ! -f "$APK" ]; then
  echo "⚠  $APK not found — skipping APK check"
else
  export JAVA_HOME="${JAVA_HOME:-/Applications/Android Studio.app/Contents/jbr/Contents/Home}"
  export PATH="$JAVA_HOME/bin:$PATH"
  got=$("$APKSIGNER" verify --print-certs "$APK" 2>/dev/null \
        | grep -i "certificate SHA-256" | grep -oiE "[0-9a-f]{64}" | head -1)
  if [ "$got" = "$EXPECT_APK" ]; then
    echo "✓ APK signed with the canonical key"
  else
    echo "✗ APK cert is $got — expected $EXPECT_APK"; fail=1
  fi
fi

# --- macOS app (inside the zip) ---
if [ ! -f "$MACZIP" ]; then
  echo "⚠  $MACZIP not found — skipping Mac check"
else
  tmp=$(mktemp -d)
  ditto -x -k "$MACZIP" "$tmp" 2>/dev/null
  app=$(find "$tmp" -maxdepth 1 -name "*.app" | head -1)
  got=$(codesign -d -r- "$app" 2>/dev/null | sed -n 's/.*leaf = H"\([^"]*\)".*/\1/p' | tr 'A-F' 'a-f')
  rm -rf "$tmp"
  if [ "$got" = "$EXPECT_MAC" ]; then
    echo "✓ Mac app signed with the canonical identity"
  else
    echo "✗ Mac app cert leaf is ${got:-none} — expected $EXPECT_MAC"; fail=1
  fi
fi

if [ "$fail" = 0 ]; then
  echo "→ Safe to publish."
else
  echo "→ DO NOT PUBLISH — a signature drifted (see SIGNING.md)."; exit 1
fi
