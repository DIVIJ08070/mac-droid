#!/bin/bash
# Bifrost Desktop Mode — opens a phone-powered Android desktop in a window on
# your Mac. Apps you launch there run in a separate virtual display, so your
# actual phone stays free. Built on scrcpy's --new-display.
#
# Requirements:
#   • scrcpy 3+          →  brew install scrcpy
#   • Phone reachable over ADB (Developer options → Wireless debugging, or USB)
#
# Usage: bifrost-desktop.sh [WIDTHxHEIGHT] [DPI]
#        bifrost-desktop.sh 1600x900 300
set -euo pipefail
export PATH="/usr/local/bin:/opt/homebrew/bin:$PATH"
ADB="${ADB:-$HOME/Library/Android/sdk/platform-tools/adb}"
export ADB

if ! command -v scrcpy >/dev/null 2>&1; then
  echo "✗ scrcpy is not installed. Run:  brew install scrcpy"
  exit 1
fi

# Any device connected?
if ! "$ADB" devices | awk 'NR>1 && $2=="device"{found=1} END{exit !found}'; then
  cat <<'EOF'
✗ No phone connected over ADB.

To use Desktop Mode, the phone must be reachable via ADB:
  1. On the phone: Settings → Developer options → Wireless debugging → ON
  2. Tap "Pair device with pairing code" and, on your Mac:
       adb pair   <phone-ip>:<pair-port>      (enter the 6-digit code)
       adb connect <phone-ip>:<debug-port>
     …or simply plug in a USB cable and allow USB debugging.
  3. Re-run this script.
EOF
  exit 1
fi

RES="${1:-1600x900}"
DPI="${2:-160}"
echo "▸ Opening Bifrost Desktop (${RES} @ ${DPI}dpi)… launch apps inside the new window."
exec scrcpy \
  --new-display="${RES}/${DPI}" \
  --stay-awake \
  --no-audio \
  --window-title="Bifrost Desktop"
