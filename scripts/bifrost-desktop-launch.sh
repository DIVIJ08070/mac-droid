#!/bin/bash
# Launches Bifrost Desktop, auto-reconnecting ADB first so it doesn't fail with
# "no device" when wireless debugging is on but the link has dropped.
# Args: [WIDTHxHEIGHT] [DPI]   (defaults 1600x900 / 160)
set -uo pipefail
export PATH="/usr/local/bin:/opt/homebrew/bin:$PATH"
ADB="${ADB:-$HOME/Library/Android/sdk/platform-tools/adb}"
export ADB

command -v scrcpy >/dev/null 2>&1 || { echo "NO_SCRCPY"; exit 2; }

device_ready() { "$ADB" devices | awk 'NR>1 && $2=="device"{f=1} END{exit !f}'; }

if ! device_ready; then
  # Kick the adb server and let mDNS rediscover the phone's wireless-debug endpoint.
  "$ADB" reconnect offline >/dev/null 2>&1
  "$ADB" kill-server >/dev/null 2>&1
  "$ADB" start-server >/dev/null 2>&1
  for i in 1 2 3 4 5 6 7 8; do
    device_ready && break
    # Try to (re)connect to any wireless-debug service mDNS is advertising.
    ep=$("$ADB" mdns services 2>/dev/null | awk '/_adb-tls-connect/{print $NF; exit}')
    [ -n "${ep:-}" ] && "$ADB" connect "$ep" >/dev/null 2>&1
    sleep 1
  done
fi

if ! device_ready; then
  echo "NO_DEVICE"
  exit 3
fi

RES="${1:-1600x900}"
DPI="${2:-160}"
echo "OK"
exec scrcpy --new-display="${RES}/${DPI}" --stay-awake --no-audio --window-title="Bifrost Desktop"
